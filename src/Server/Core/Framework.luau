--!strict
--[[
	ACF framework orchestrator.

	Owns the core services (configuration, logger, event bus, scheduler, player registry,
	evidence, detection pipeline, module loader) and drives the framework lifecycle:

	  Created --Initialize(config)--> Initialized --Start()--> Running
	  Running --Stop()--> Stopped --Start()--> Running
	  any --Destroy()--> Destroyed

	Error policy:
	  - Developer errors (invalid configuration, invalid module definitions, calls in the
	    wrong state, a Critical module failing to start) raise immediately with a clear
	    message. Failing loudly at boot is safer than running half-configured.
	  - Runtime faults inside modules, event handlers and scheduled tasks are isolated,
	    logged and never propagate into the framework.

	Framework does not touch Roblox globals. All platform access goes through the
	Environment passed to new(); see Platform/RobloxEnvironment.
]]

local Constants = require(game:GetService("ReplicatedStorage"):WaitForChild("ACFShared"):WaitForChild("Constants"))
local Cleanup = require(script.Parent.Cleanup)
local Configuration = require(script.Parent.Configuration)
local DefaultConfig = require(script.Parent.DefaultConfig)
local EventBus = require(script.Parent.EventBus)
local Logger = require(script.Parent.Logger)
local ModuleLoader = require(script.Parent.ModuleLoader)
local PlayerRegistry = require(script.Parent.PlayerRegistry)
local Scheduler = require(script.Parent.Scheduler)
local Topics = require(script.Parent.Topics)
local BuiltIns = require(script.Parent.Parent.Detection.BuiltIns)
local DetectionManager = require(script.Parent.Parent.Detection.DetectionManager)
local EvidenceManager = require(script.Parent.Parent.Intelligence.EvidenceManager)
local RiskEngine = require(script.Parent.Parent.Intelligence.RiskEngine)
local EnforcementManager = require(script.Parent.Parent.Enforcement.EnforcementManager)
local Types = require(script.Parent.Parent.Types)

type FrameworkState = Types.FrameworkState
type ModuleDefinition = Types.ModuleDefinition

local MODULE_SETTINGS = "ModuleSettings"

-- Built-in module names reserved for later phases. Enabling one in configuration
-- before it ships produces a warning rather than silently doing nothing.
-- Built-in modules announced for a later phase (name -> phase). Configuring one of
-- these logs "not available in this ACF version" instead of "not registered".
local PLANNED_BUILTINS: { [string]: string } = table.freeze({})

type Services = {
	Config: Configuration.Configuration,
	Logger: Logger.Logger,
	Bus: EventBus.EventBus,
	Scheduler: Scheduler.Scheduler,
	Registry: PlayerRegistry.PlayerRegistry,
	Evidence: EvidenceManager.EvidenceManager,
	Detections: DetectionManager.DetectionManager,
	-- nil when Risk.Enabled = false.
	Risk: RiskEngine.RiskEngine?,
	Enforcement: EnforcementManager.EnforcementManager,
	Loader: ModuleLoader.ModuleLoader,
}

local Framework = {}
Framework.__index = Framework
Framework.Version = Constants.VERSION
Framework.Channel = Constants.CHANNEL

export type Framework = typeof(setmetatable(
	{} :: {
		_env: Types.Environment,
		_state: FrameworkState,
		_services: Services?,
		_queued: { ModuleDefinition },
		_runCleanup: Cleanup.Cleanup?,
		_resolved: boolean,
	},
	Framework
))

local function validateEnvironment(env: any)
	assert(type(env) == "table", "ACF: Framework.new requires an Environment table")
	assert(env.Players ~= nil, "ACF: Environment.Players is required")
	assert(type(env.Clock) == "table", "ACF: Environment.Clock is required")
	assert(type(env.Clock.Now) == "function", "ACF: Environment.Clock.Now must be a function")
	assert(type(env.Clock.Wall) == "function", "ACF: Environment.Clock.Wall must be a function")
	assert(type(env.GenerateId) == "function", "ACF: Environment.GenerateId must be a function")
end

function Framework.new(environment: Types.Environment): Framework
	validateEnvironment(environment)
	return setmetatable({
		_env = environment,
		_state = "Created" :: FrameworkState,
		_services = nil,
		_queued = {},
		_runCleanup = nil,
		_resolved = false,
	}, Framework)
end

local function setState(self: Framework, to: FrameworkState)
	local from = self._state
	self._state = to
	local services = self._services
	if services and to ~= "Destroyed" then
		services.Bus:Publish(Topics.FrameworkStateChanged, { From = from, To = to })
	end
end

local function requireServices(self: Framework, action: string): Services
	local services = self._services
	if services == nil then
		error(`ACF: {action} requires Initialize() to be called first`, 3)
	end
	return services
end

local function formatErrors(header: string, errors: { string }): string
	return header .. "\n  - " .. table.concat(errors, "\n  - ")
end

-- A Player, Session or UserId -> UserId.
local function resolveTarget(target: any): number?
	if type(target) == "number" then
		return target
	end
	local ok, userId = pcall(function()
		return target.UserId
	end)
	return if ok and type(userId) == "number" then userId else nil
end

-- Module context ---------------------------------------------------------------------

local function makeContext(self: Framework, services: Services, entry: ModuleLoader.ModuleEntry): Types.ModuleContext
	local name = entry.Name
	local config = services.Config
	local moduleConfig = config:Get(`{MODULE_SETTINGS}.{name}`) or table.freeze({})

	local function bag(): Cleanup.Cleanup
		return entry.ActiveCleanup
	end

	local events = table.freeze({
		Subscribe = function(_, topic: string, handler: (any) -> ())
			return bag():Add(services.Bus:Subscribe(topic, handler, name))
		end,
		-- Declares a module-owned topic "<ModuleName>.<suffix>" and returns its full name.
		Declare = function(_, suffix: string): string
			if type(suffix) ~= "string" or not string.match(suffix, "^[%a][%w_]*$") then
				error("Events:Declare expects an identifier suffix", 2)
			end
			local topic = `{name}.{suffix}`
			services.Bus:RegisterTopic(topic)
			return topic
		end,
		-- True when a topic exists (another module may be disabled and not declare it).
		Has = function(_, topic: string): boolean
			return services.Bus:HasTopic(topic)
		end,
		Publish = function(_, topic: string, payload: any): number
			if type(topic) ~= "string" or string.sub(topic, 1, #name + 1) ~= name .. "." then
				error(`module '{name}' may only publish its own topics ('{name}.*'); got '{tostring(topic)}'`, 2)
			end
			return services.Bus:Publish(topic, payload)
		end,
	})

	local scheduler = table.freeze({
		Every = function(_, taskName: string, interval: number, callback, phase: number?)
			return bag():Add(services.Scheduler:Every(`{name}.{taskName}`, interval, callback, phase))
		end,
		After = function(_, taskName: string, delay: number, callback)
			return bag():Add(services.Scheduler:After(`{name}.{taskName}`, delay, callback))
		end,
	})

	local players = table.freeze({
		GetSession = function(_, target: any)
			return services.Registry:GetSession(target)
		end,
		GetSessions = function(_)
			return services.Registry:GetSessions()
		end,
	})

	-- The Cleanup facade routes to the lifetime bag during Initialize and to the run
	-- bag afterwards, matching the facades above.
	local cleanup = table.freeze({
		Add = function(_, item: any)
			return bag():Add(item)
		end,
	})

	-- Read-only questions modules may ask about enforcement; they never decide it.
	local enforcementFacade = table.freeze({
		IsRestricted = function(_, target: any, tag: string | boolean, operation: string?): boolean
			local userId = resolveTarget(target)
			return userId ~= nil and services.Enforcement:IsRestricted(userId, tag, operation or name)
		end,
		ShouldCorrect = function(_, target: any): boolean
			local userId = resolveTarget(target)
			return userId ~= nil and services.Enforcement:ShouldCorrect(userId)
		end,
		NoteCorrected = function(_, target: any, details: { [string]: any })
			local userId = resolveTarget(target)
			if userId ~= nil then
				services.Enforcement:NoteCorrected(userId, details)
			end
		end,
	})

	local context: Types.ModuleContext = table.freeze({
		Name = name,
		Config = moduleConfig,
		Logger = services.Logger:Scope(name),
		Clock = self._env.Clock,
		Cleanup = cleanup,
		Events = events,
		Scheduler = scheduler,
		Players = players,
		Platform = table.freeze({ Physics = self._env.Physics, Remotes = self._env.Remotes }),
		Enforcement = enforcementFacade,
		Report = function(_, target: any, input: Types.DetectionInput): (boolean, string)
			return services.Detections:Report(entry, target, input)
		end,
		GetConfig = function(_, path: string): any
			return config:Get(path)
		end,
		GetModule = function(_, other: string): any
			if not table.find(entry.Dependencies, other) then
				error(`module '{name}' did not declare '{other}' in Dependencies`, 2)
			end
			local dep = services.Loader:Get(other)
			return if dep then dep.Definition else nil
		end,
	}) :: any
	return context
end

-- Lifecycle --------------------------------------------------------------------------

function Framework.Initialize(self: Framework, userConfig: { [string]: any }?)
	if self._state ~= "Created" then
		error(`ACF: Initialize can only be called once (state is {self._state})`, 2)
	end
	local env = self._env

	local config = Configuration.new(DefaultConfig())
	local ok, errors = config:Load(userConfig)
	if not ok then
		error(formatErrors("ACF configuration is invalid:", errors), 2)
	end

	local level = if config:Get("Debug") then "Debug" else config:Get("LogLevel")
	local rootLogger = Logger.new({
		Level = level,
		BufferSize = config:Get("Logging.BufferSize"),
		RateLimitBurst = config:Get("Logging.RateLimitBurst"),
		RateLimitWindowSeconds = config:Get("Logging.RateLimitWindowSeconds"),
		Now = env.Clock.Now,
		Wall = env.Clock.Wall,
		Sink = env.LogSink,
	})

	local bus = EventBus.new({
		Logger = rootLogger:Scope("Core.EventBus"),
		Strict = true,
		MaxHandlerFailures = config:Get("EventBus.MaxHandlerFailures"),
		MaxDispatchDepth = config:Get("EventBus.MaxDispatchDepth"),
	})
	for _, topic: string in Topics :: any do
		bus:RegisterTopic(topic)
	end

	local scheduler = Scheduler.new({
		Now = env.Clock.Now,
		Logger = rootLogger:Scope("Core.Scheduler"),
		MaxConsecutiveFailures = config:Get("Scheduler.MaxConsecutiveFailures"),
	})

	local registry = PlayerRegistry.new({
		Players = env.Players,
		Bus = bus,
		Logger = rootLogger:Scope("Core.Players"),
		Clock = env.Clock,
		GenerateId = env.GenerateId,
	})

	local evidence = EvidenceManager.new({
		Clock = env.Clock,
		Logger = rootLogger:Scope("Intelligence.Evidence"),
		GenerateId = env.GenerateId,
		Settings = config:Get("Evidence"),
	})

	local detections = DetectionManager.new({
		Registry = registry,
		Evidence = evidence,
		Bus = bus,
		Logger = rootLogger:Scope("Detection"),
		Clock = env.Clock,
		GenerateId = env.GenerateId,
		Settings = config:Get("Detection"),
	})

	local risk: RiskEngine.RiskEngine? = nil
	if config:Get("Risk.Enabled") then
		local riskOk, created = pcall(RiskEngine.new, {
			Bus = bus,
			Registry = registry,
			Logger = rootLogger:Scope("Intelligence.Risk"),
			Clock = env.Clock,
			Settings = config:Get("Risk"),
			Store = env.Store,
			OnShutdown = env.OnShutdown,
		})
		if not riskOk then
			bus:Destroy()
			error(tostring(created), 2)
		end
		risk = created
	end

	-- Created after the RiskEngine so its DetectionReported handler runs after risk has
	-- been updated (the bus calls handlers in subscription order).
	local enforcement = EnforcementManager.new({
		Bus = bus,
		Registry = registry,
		Logger = rootLogger:Scope("Enforcement"),
		Clock = env.Clock,
		GenerateId = env.GenerateId,
		Settings = config:Get("Enforcement"),
		Risk = risk,
		Store = env.Store,
		Enforcer = env.Enforcer,
	})

	local services: Services
	local loader = ModuleLoader.new({
		Logger = rootLogger:Scope("Core.Modules"),
		Bus = bus,
		MakeContext = function(entry)
			return makeContext(self, services, entry)
		end,
	})

	services = {
		Config = config,
		Logger = rootLogger,
		Bus = bus,
		Scheduler = scheduler,
		Registry = registry,
		Evidence = evidence,
		Detections = detections,
		Risk = risk,
		Enforcement = enforcement,
		Loader = loader,
	}

	-- Register built-ins, then modules queued before Initialize. Everything is
	-- validated before committing, so a failed Initialize leaves the framework in Created.
	local definitions: { ModuleDefinition } = {}
	for _, factory in BuiltIns do
		table.insert(definitions, factory())
	end
	for _, definition in self._queued do
		table.insert(definitions, definition)
	end
	for _, definition in definitions do
		loader:Register(definition)
		if definition.ConfigSchema then
			local extendOk, extendErrors = config:Extend(MODULE_SETTINGS, definition.Name, definition.ConfigSchema)
			if not extendOk then
				error(formatErrors(`ACF configuration for module '{definition.Name}' is invalid:`, extendErrors), 2)
			end
		end
	end
	table.clear(self._queued)

	self._services = services
	setState(self, "Initialized")
	rootLogger:Info("Framework initialized", { Version = Constants.VERSION, Channel = Constants.CHANNEL })
end

-- Registers a module. Allowed before Initialize (queued) or between Initialize and the
-- first Start. Raises on invalid definitions or invalid module configuration.
function Framework.RegisterModule(self: Framework, definition: ModuleDefinition)
	local state = self._state
	if state == "Created" then
		local problem = ModuleLoader.Validate(definition)
		if problem then
			error("ACF: " .. problem, 2)
		end
		for _, queued in self._queued do
			if queued.Name == definition.Name then
				error(`ACF: a module named '{definition.Name}' is already registered`, 2)
			end
		end
		table.insert(self._queued, definition)
		return
	end
	if state ~= "Initialized" or self._resolved then
		error(`ACF: modules must be registered before the first Start (state is {state})`, 2)
	end
	local services = requireServices(self, "RegisterModule")
	services.Loader:Register(definition)
	if definition.ConfigSchema then
		local ok, errors = services.Config:Extend(MODULE_SETTINGS, definition.Name, definition.ConfigSchema)
		if not ok then
			error(formatErrors(`ACF configuration for module '{definition.Name}' is invalid:`, errors), 2)
		end
	end
end

local function resolveModules(self: Framework, services: Services)
	local config = services.Config
	local unclaimed = config:UnclaimedKeys()
	if #unclaimed > 0 then
		local errors = {}
		for _, path in unclaimed do
			table.insert(errors, `{path}: no registered module with a ConfigSchema has this name`)
		end
		error(formatErrors("ACF configuration is invalid:", errors), 3)
	end

	local enabledMap: { [string]: boolean } = config:Get("Modules")
	for moduleName, enabled in enabledMap do
		if enabled and not services.Loader:Has(moduleName) then
			local phase = PLANNED_BUILTINS[moduleName]
			if phase then
				services.Logger:Warn("Configured module is not available in this ACF version", {
					Module = moduleName,
					PlannedFor = phase,
					Version = Constants.VERSION,
				})
			else
				services.Logger:Warn("Configured module is not registered", { Module = moduleName })
			end
		end
	end

	services.Loader:Resolve(function(entry)
		local configured = enabledMap[entry.Name]
		if configured ~= nil then
			return configured
		end
		return entry.Definition.EnabledByDefault ~= false
	end)
	services.Loader:InitializeAll()
	self._resolved = true
end

-- Starts the framework. Returns a status snapshot. Raises if a Critical module fails.
function Framework.Start(self: Framework): { [string]: any }
	local state = self._state
	if state ~= "Initialized" and state ~= "Stopped" then
		error(`ACF: Start requires state Initialized or Stopped (state is {state})`, 2)
	end
	local services = requireServices(self, "Start")

	if not self._resolved then
		resolveModules(self, services)
	end
	services.Loader:StartAll()

	local criticalFailures = {}
	for name, info in services.Loader:GetStates() do
		if info.Critical and info.State ~= "Running" and info.State ~= "Disabled" then
			table.insert(criticalFailures, `{name} ({info.State}{if info.Error then ": " .. info.Error else ""})`)
		end
	end
	if #criticalFailures > 0 then
		table.sort(criticalFailures)
		services.Loader:StopAll()
		error(formatErrors("ACF: critical modules failed to start:", criticalFailures), 2)
	end

	local runCleanup = Cleanup.new(function(message)
		services.Logger:Error("Framework cleanup task failed", { Error = message })
	end)
	runCleanup:Add(services.Scheduler:Every("ACF.EvidencePrune", services.Config:Get("Evidence.PruneIntervalSeconds"), function()
		services.Evidence:Prune()
	end))
	if services.Risk then
		services.Risk:Start(services.Scheduler, runCleanup)
	end
	services.Enforcement:Start(services.Scheduler, runCleanup, self._env.OnShutdown)
	local heartbeat = self._env.Heartbeat
	if heartbeat ~= nil then
		services.Scheduler:Bind(heartbeat)
		runCleanup:Add(function()
			services.Scheduler:Unbind()
		end)
	end
	self._runCleanup = runCleanup

	setState(self, "Running")
	-- Sessions start after modules are running so modules observe every join,
	-- including players already in the server.
	services.Registry:Start()
	services.Logger:Info("Framework started", {
		Modules = #services.Loader:InState("Running"),
		Players = services.Registry:Count(),
	})
	return self:GetStatus()
end

function Framework.Stop(self: Framework)
	if self._state ~= "Running" then
		return
	end
	local services = requireServices(self, "Stop")
	-- End sessions first so modules receive PlayerSessionEnded while still running.
	services.Registry:Stop()
	if services.Risk then
		-- Sessions have ended (and queued their risk records); write them now.
		services.Risk:Stop()
	end
	services.Enforcement:Stop()
	services.Loader:StopAll()
	local runCleanup = self._runCleanup
	if runCleanup then
		runCleanup:Clean()
		self._runCleanup = nil
	end
	setState(self, "Stopped")
	services.Logger:Info("Framework stopped")
end

function Framework.Destroy(self: Framework)
	if self._state == "Destroyed" then
		return
	end
	self:Stop()
	local services = self._services
	if services then
		services.Loader:DestroyAll()
		services.Scheduler:Destroy()
		services.Evidence:Clear()
		if services.Risk then
			services.Risk:Destroy()
		end
		services.Enforcement:Destroy()
		services.Logger:Info("Framework destroyed")
		services.Bus:Destroy()
	end
	table.clear(self._queued)
	setState(self, "Destroyed")
end

-- Advances the scheduler once. Production code never needs this (Heartbeat drives it);
-- hosts without a Heartbeat signal, such as tests, call it manually.
function Framework.Step(self: Framework)
	if self._state ~= "Running" then
		return
	end
	requireServices(self, "Step").Scheduler:Step()
end

-- Queries ----------------------------------------------------------------------------

function Framework.GetState(self: Framework): FrameworkState
	return self._state
end

function Framework.GetStatus(self: Framework): { [string]: any }
	local services = self._services
	if services == nil then
		return { State = self._state, Version = Constants.VERSION, Channel = Constants.CHANNEL, QueuedModules = #self._queued }
	end
	return {
		State = self._state,
		Version = Constants.VERSION,
		Channel = Constants.CHANNEL,
		Modules = services.Loader:GetStates(),
		ModuleOrder = services.Loader:GetOrder(),
		Players = services.Registry:GetStats(),
		Evidence = services.Evidence:GetStats(),
		Detections = services.Detections:GetStats(),
		Risk = if services.Risk then services.Risk:GetStats() else nil,
		Enforcement = services.Enforcement:GetStats(),
		EventBus = services.Bus:GetStats(),
		Scheduler = services.Scheduler:GetStats(),
		Logging = services.Logger:GetStats(),
	}
end

function Framework.GetSession(self: Framework, target: any): PlayerRegistry.Session?
	return requireServices(self, "GetSession").Registry:GetSession(target)
end

function Framework.GetSessions(self: Framework): { PlayerRegistry.Session }
	return requireServices(self, "GetSessions").Registry:GetSessions()
end

local function resolveUserId(target: any): number?
	if type(target) == "number" then
		return target
	end
	local ok, userId = pcall(function()
		return target.UserId
	end)
	return if ok and type(userId) == "number" then userId else nil
end

-- Evidence for a Player, Session or UserId. Works after the player has left, until the
-- records expire.
function Framework.GetEvidence(self: Framework, target: any, filter: any?): { Types.EvidenceRecord }
	local services = requireServices(self, "GetEvidence")
	local userId = resolveUserId(target)
	if userId == nil then
		error("ACF: GetEvidence expects a Player, Session or UserId", 2)
	end
	return services.Evidence:Get(userId, filter)
end

function Framework.GetEvidenceSummary(self: Framework, target: any): EvidenceManager.EvidenceSummary
	local services = requireServices(self, "GetEvidenceSummary")
	local userId = resolveUserId(target)
	if userId == nil then
		error("ACF: GetEvidenceSummary expects a Player, Session or UserId", 2)
	end
	return services.Evidence:Summary(userId)
end

local function riskFor(self: Framework, action: string, target: any): (RiskEngine.RiskEngine, number)
	local services = requireServices(self, action)
	local userId = resolveUserId(target)
	if userId == nil then
		error(`ACF: {action} expects a Player, Session or UserId`, 3)
	end
	local risk = services.Risk
	if risk == nil then
		error("ACF: risk assessment is disabled (Risk.Enabled = false)", 3)
	end
	return risk, userId
end

-- Current risk for a Player, Session or UserId, with groups and an explanation.
function Framework.GetRisk(self: Framework, target: any): RiskEngine.RiskReport
	local risk, userId = riskFor(self, "GetRisk", target)
	return risk:Get(userId)
end

-- Risk history (detections that changed risk, band changes, loaded history, resets).
function Framework.GetRiskHistory(self: Framework, target: any): { RiskEngine.HistoryEntry }
	local risk, userId = riskFor(self, "GetRiskHistory", target)
	return risk:GetHistory(userId)
end

-- Staff override: clears a user's risk; options = { Persistent = true, Reason = "..." }.
function Framework.ResetRisk(self: Framework, target: any, options: { Persistent: boolean?, Reason: string? }?)
	local risk, userId = riskFor(self, "ResetRisk", target)
	risk:Reset(userId, options)
end

-- Enforcement (Phase 7) ------------------------------------------------------------

local function enforcementFor(self: Framework, action: string, target: any): (EnforcementManager.EnforcementManager, number)
	local services = requireServices(self, action)
	local userId = resolveUserId(target)
	if userId == nil then
		error(`ACF: {action} expects a Player, Session or UserId`, 3)
	end
	return services.Enforcement, userId
end

function Framework.GetEnforcement(self: Framework, target: any): { [string]: any }
	local enforcement, userId = enforcementFor(self, "GetEnforcement", target)
	return enforcement:Get(userId)
end

function Framework.IsRestricted(self: Framework, target: any, tag: string | boolean, operation: string?): boolean
	local enforcement, userId = enforcementFor(self, "IsRestricted", target)
	return enforcement:IsRestricted(userId, tag, operation or "Game")
end

function Framework.Kick(self: Framework, target: any, options: { By: any, Reason: string? }): string
	local enforcement, userId = enforcementFor(self, "Kick", target)
	return enforcement:Kick(userId, options)
end

function Framework.Ban(self: Framework, target: any, options: { By: any, Reason: string?, Hours: number? }): string
	local enforcement, userId = enforcementFor(self, "Ban", target)
	return enforcement:Ban(userId, options)
end

function Framework.Unban(self: Framework, target: any, options: { By: any, Reason: string? })
	local enforcement, userId = enforcementFor(self, "Unban", target)
	enforcement:Unban(userId, options)
end

function Framework.SetEnforcementOverride(self: Framework, target: any, options: { [string]: any })
	local enforcement, userId = enforcementFor(self, "SetEnforcementOverride", target)
	enforcement:SetOverride(userId, options)
end

function Framework.ClearEnforcementOverride(self: Framework, target: any, options: { By: any, Reason: string? })
	local enforcement, userId = enforcementFor(self, "ClearEnforcementOverride", target)
	enforcement:ClearOverride(userId, options)
end

function Framework.LoadEnforcementRecord(self: Framework, target: any, callback: (any) -> ())
	local enforcement, userId = enforcementFor(self, "LoadEnforcementRecord", target)
	enforcement:LoadRecord(userId, callback)
end

function Framework.GetCases(self: Framework, filter: { Status: string?, UserId: number? }?): { EnforcementManager.Case }
	return requireServices(self, "GetCases").Enforcement:GetCases(filter)
end

function Framework.ApproveCase(self: Framework, caseId: string, options: { By: any, Level: number?, Note: string?, Hours: number? })
	requireServices(self, "ApproveCase").Enforcement:Approve(caseId, options)
end

function Framework.RejectCase(self: Framework, caseId: string, options: { By: any, Note: string? })
	requireServices(self, "RejectCase").Enforcement:Reject(caseId, options)
end

function Framework.GetAuditLog(self: Framework, filter: { UserId: number?, Type: string?, Since: number? }?): { { [string]: any } }
	return requireServices(self, "GetAuditLog").Enforcement:GetAudit(filter)
end

-- Subscribes to a core topic (see Core/Topics). Returns a subscription with Disconnect().
function Framework.Subscribe(self: Framework, topic: string, handler: (any) -> ()): EventBus.Subscription
	return requireServices(self, "Subscribe").Bus:Subscribe(topic, handler, "External")
end

function Framework.OnDetection(self: Framework, handler: (any) -> ()): EventBus.Subscription
	return self:Subscribe(Topics.DetectionReported, handler)
end

-- Returns a registered module's definition table (its public surface), or nil.
function Framework.GetModule(self: Framework, name: string): ModuleDefinition?
	local entry = requireServices(self, "GetModule").Loader:Get(name)
	return if entry then entry.Definition else nil
end

-- State of a registered module ("Running", "Disabled", ...), or nil if unknown.
function Framework.GetModuleState(self: Framework, name: string): Types.ModuleState?
	local entry = requireServices(self, "GetModuleState").Loader:Get(name)
	return if entry then entry.State else nil
end

function Framework.GetConfig(self: Framework, path: string): any
	return requireServices(self, "GetConfig").Config:Get(path)
end

function Framework.GetRecentLogs(self: Framework, count: number?): { Types.LogEntry }
	return requireServices(self, "GetRecentLogs").Logger:GetRecent(count)
end

return Framework
