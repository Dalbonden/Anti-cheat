--!strict
--[[
	Module registration, dependency resolution and lifecycle management.

	Every module goes through an explicit state machine (see TRANSITIONS). Illegal
	transitions raise immediately; they indicate a framework bug, not a module bug.

	Lifecycle:
	  Resolve()       topological sort by Dependencies; disabled, missing and cyclic
	                  dependencies are detected here.
	  InitializeAll() Initialize(context) in dependency order.
	  StartAll()      Start() in dependency order.
	  StopAll()       Stop() in reverse order. Resources added to context.Cleanup or
	                  acquired through context facades during Start are released here.
	  DestroyAll()    Destroy() in reverse order. Resources acquired during Initialize
	                  are released here.

	Error isolation: each lifecycle call runs in pcall. A module that throws becomes
	Failed, its resources are released, and every module that depends on it (directly
	or transitively) becomes Blocked. Other modules keep running.
]]

local Cleanup = require(script.Parent.Cleanup)
local EventBus = require(script.Parent.EventBus)
local Logger = require(script.Parent.Logger)
local Topics = require(script.Parent.Topics)
local Types = require(script.Parent.Parent.Types)

type ModuleState = Types.ModuleState
type ModuleDefinition = Types.ModuleDefinition

local TRANSITIONS: { [string]: { [string]: boolean } } = {
	Registered = { Initializing = true, Disabled = true, Blocked = true, Failed = true },
	Initializing = { Initialized = true, Failed = true },
	Initialized = { Starting = true, Blocked = true, Destroying = true },
	Starting = { Running = true, Failed = true },
	Running = { Stopping = true },
	Stopping = { Stopped = true, Failed = true },
	Stopped = { Starting = true, Blocked = true, Destroying = true },
	Failed = { Destroying = true, Destroyed = true },
	Blocked = { Destroying = true, Destroyed = true, Starting = true },
	Disabled = { Destroyed = true },
	Destroying = { Destroyed = true },
	Destroyed = {},
}

local VALID_CATEGORIES = {
	Movement = true,
	Physics = true,
	Remote = true,
	Combat = true,
	Economy = true,
	Behavioral = true,
	Integrity = true,
	Custom = true,
}

local LIFECYCLE_METHODS = { "Initialize", "Start", "Stop", "Destroy" }

export type ModuleEntry = {
	Name: string,
	Definition: ModuleDefinition,
	Category: Types.DetectionCategory,
	Dependencies: { string },
	Critical: boolean,
	State: ModuleState,
	Error: string?,
	WasInitialized: boolean,
	Order: number,
	Context: any?,
	RunCleanup: Cleanup.Cleanup,
	LifetimeCleanup: Cleanup.Cleanup,
	-- Bag that context facades add to: lifetime during Initialize, run otherwise.
	ActiveCleanup: Cleanup.Cleanup,
}

local ModuleLoader = {}
ModuleLoader.__index = ModuleLoader

export type ModuleLoader = typeof(setmetatable(
	{} :: {
		_logger: Logger.Logger,
		_bus: EventBus.EventBus,
		_makeContext: (entry: ModuleEntry) -> any,
		_entries: { [string]: ModuleEntry },
		_registrationOrder: { ModuleEntry },
		_order: { ModuleEntry }?,
	},
	ModuleLoader
))

export type ModuleLoaderOptions = {
	Logger: Logger.Logger,
	Bus: EventBus.EventBus,
	MakeContext: (entry: ModuleEntry) -> any,
}

function ModuleLoader.new(options: ModuleLoaderOptions): ModuleLoader
	return setmetatable({
		_logger = options.Logger,
		_bus = options.Bus,
		_makeContext = options.MakeContext,
		_entries = {},
		_registrationOrder = {},
		_order = nil,
	}, ModuleLoader)
end

-- Validates a module definition. Returns nil when valid, otherwise an error message.
function ModuleLoader.Validate(definition: any): string?
	if type(definition) ~= "table" then
		return `module definition must be a table, got {typeof(definition)}`
	end
	local name = definition.Name
	if type(name) ~= "string" or not string.match(name, "^[%a][%w_]*$") or #name > 48 then
		return "module Name must be an identifier (letters, digits, underscore; max 48 chars)"
	end
	for _, method in LIFECYCLE_METHODS do
		if type(definition[method]) ~= "function" then
			return `module '{name}' must implement {method}()`
		end
	end
	local deps = definition.Dependencies
	if deps ~= nil then
		if type(deps) ~= "table" then
			return `module '{name}': Dependencies must be an array of module names`
		end
		local seen = {}
		for _, dep in deps do
			if type(dep) ~= "string" then
				return `module '{name}': Dependencies must contain only strings`
			end
			if dep == name then
				return `module '{name}' cannot depend on itself`
			end
			if seen[dep] then
				return `module '{name}' lists dependency '{dep}' twice`
			end
			seen[dep] = true
		end
	end
	if definition.Category ~= nil and not VALID_CATEGORIES[definition.Category] then
		return `module '{name}': unknown Category '{tostring(definition.Category)}'`
	end
	if definition.Version ~= nil and type(definition.Version) ~= "string" then
		return `module '{name}': Version must be a string`
	end
	if definition.Critical ~= nil and type(definition.Critical) ~= "boolean" then
		return `module '{name}': Critical must be a boolean`
	end
	if definition.EnabledByDefault ~= nil and type(definition.EnabledByDefault) ~= "boolean" then
		return `module '{name}': EnabledByDefault must be a boolean`
	end
	local schema = definition.ConfigSchema
	if schema ~= nil and (type(schema) ~= "table" or schema.Kind ~= "table") then
		return `module '{name}': ConfigSchema must be built with Schema.Table`
	end
	return nil
end

local function transition(self: ModuleLoader, entry: ModuleEntry, to: ModuleState, err: string?)
	local from = entry.State
	if not TRANSITIONS[from][to] then
		error(`ModuleLoader: illegal transition {from} -> {to} for module '{entry.Name}'`, 2)
	end
	entry.State = to
	if err ~= nil then
		entry.Error = err
	elseif to ~= "Failed" and to ~= "Blocked" then
		entry.Error = nil
	end
	self._bus:Publish(Topics.ModuleStateChanged, { Name = entry.Name, From = from, To = to, Error = err })
end

function ModuleLoader.Register(self: ModuleLoader, definition: ModuleDefinition): ModuleEntry
	local problem = ModuleLoader.Validate(definition)
	if problem then
		error("ACF: " .. problem, 3)
	end
	if self._order ~= nil then
		error(`ACF: cannot register module '{definition.Name}' after modules have been resolved`, 3)
	end
	if self._entries[definition.Name] then
		error(`ACF: a module named '{definition.Name}' is already registered`, 3)
	end

	local logger = self._logger
	local name = definition.Name
	local function onCleanupError(message: string)
		logger:Error("Module resource cleanup failed", { Module = name, Error = message })
	end
	local lifetime = Cleanup.new(onCleanupError)
	local entry: ModuleEntry = {
		Name = name,
		Definition = definition,
		Category = definition.Category or "Custom",
		Dependencies = table.freeze(table.clone(definition.Dependencies or {})),
		Critical = definition.Critical == true,
		State = "Registered",
		Error = nil,
		WasInitialized = false,
		Order = #self._registrationOrder + 1,
		Context = nil,
		RunCleanup = Cleanup.new(onCleanupError),
		LifetimeCleanup = lifetime,
		ActiveCleanup = lifetime,
	}
	self._entries[name] = entry
	table.insert(self._registrationOrder, entry)
	return entry
end

function ModuleLoader.Has(self: ModuleLoader, name: string): boolean
	return self._entries[name] ~= nil
end

function ModuleLoader.Get(self: ModuleLoader, name: string): ModuleEntry?
	return self._entries[name]
end

-- Decides which modules run and in what order. `isEnabled` maps an entry to whether
-- configuration enables it. Must be called once, before InitializeAll().
function ModuleLoader.Resolve(self: ModuleLoader, isEnabled: (entry: ModuleEntry) -> boolean)
	if self._order ~= nil then
		error("ModuleLoader:Resolve called twice", 2)
	end
	local entries = self._registrationOrder

	for _, entry in entries do
		if not isEnabled(entry) then
			transition(self, entry, "Disabled")
		end
	end

	-- Propagate missing/disabled dependencies until nothing changes.
	local changed = true
	while changed do
		changed = false
		for _, entry in entries do
			if entry.State == "Registered" then
				for _, depName in entry.Dependencies do
					local dep = self._entries[depName]
					local reason: string? = nil
					if dep == nil then
						reason = `missing dependency '{depName}'`
					elseif dep.State == "Disabled" then
						reason = `dependency '{depName}' is disabled`
					elseif dep.State == "Blocked" or dep.State == "Failed" then
						reason = `dependency '{depName}' is unavailable`
					end
					if reason then
						transition(self, entry, "Blocked", reason)
						self._logger:Warn("Module blocked", { Module = entry.Name, Reason = reason })
						changed = true
						break
					end
				end
			end
		end
	end

	-- Kahn's algorithm over the remaining modules; ties broken by registration order.
	local inDegree: { [string]: number } = {}
	local dependents: { [string]: { ModuleEntry } } = {}
	local pending = {}
	for _, entry in entries do
		if entry.State == "Registered" then
			inDegree[entry.Name] = #entry.Dependencies
			table.insert(pending, entry)
			for _, depName in entry.Dependencies do
				dependents[depName] = dependents[depName] or {}
				table.insert(dependents[depName], entry)
			end
		end
	end

	local order: { ModuleEntry } = {}
	local ready: { ModuleEntry } = {}
	for _, entry in pending do
		if inDegree[entry.Name] == 0 then
			table.insert(ready, entry)
		end
	end
	while #ready > 0 do
		table.sort(ready, function(a, b)
			return a.Order < b.Order
		end)
		local entry = table.remove(ready, 1) :: ModuleEntry
		table.insert(order, entry)
		local waiting = dependents[entry.Name]
		if waiting then
			for _, dependent in waiting do
				inDegree[dependent.Name] -= 1
				if inDegree[dependent.Name] == 0 then
					table.insert(ready, dependent)
				end
			end
		end
	end

	if #order < #pending then
		local stuck = {}
		for _, entry in pending do
			if inDegree[entry.Name] > 0 then
				table.insert(stuck, entry.Name)
			end
		end
		table.sort(stuck)
		local reason = "dependency cycle among: " .. table.concat(stuck, ", ")
		for _, entry in pending do
			if inDegree[entry.Name] > 0 then
				transition(self, entry, "Failed", reason)
			end
		end
		self._logger:Error("Module dependency cycle", { Modules = table.concat(stuck, ", ") })
	end

	self._order = order
end

local function dependenciesIn(self: ModuleLoader, entry: ModuleEntry, states: { [string]: boolean }): string?
	for _, depName in entry.Dependencies do
		local dep = self._entries[depName]
		if dep == nil or not states[dep.State] then
			return depName
		end
	end
	return nil
end

local function runLifecycle(entry: ModuleEntry, method: string, ...: any): (boolean, string?)
	local definition = entry.Definition
	local ok, err = pcall(definition[method], definition, ...)
	if ok then
		return true, nil
	end
	return false, tostring(err)
end

local INITIALIZED_OK = { Initialized = true }
local RUNNING_OK = { Running = true }

function ModuleLoader.InitializeAll(self: ModuleLoader)
	local order = self._order
	if order == nil then
		error("ModuleLoader:InitializeAll called before Resolve", 2)
	end
	for _, entry in order do
		if entry.State == "Registered" then
			local badDep = dependenciesIn(self, entry, INITIALIZED_OK)
			if badDep then
				transition(self, entry, "Blocked", `dependency '{badDep}' failed to initialize`)
			else
				transition(self, entry, "Initializing")
				entry.Context = self._makeContext(entry)
				entry.ActiveCleanup = entry.LifetimeCleanup
				entry.WasInitialized = true
				local ok, err = runLifecycle(entry, "Initialize", entry.Context)
				entry.ActiveCleanup = entry.RunCleanup
				if ok then
					transition(self, entry, "Initialized")
				else
					entry.LifetimeCleanup:Clean()
					transition(self, entry, "Failed", `Initialize: {err}`)
					self._logger:Error("Module failed to initialize", { Module = entry.Name, Error = err })
				end
			end
		end
	end
end

function ModuleLoader.StartAll(self: ModuleLoader)
	local order = self._order
	if order == nil then
		error("ModuleLoader:StartAll called before Resolve", 2)
	end
	for _, entry in order do
		local state = entry.State
		local startable = state == "Initialized"
			or state == "Stopped"
			or (state == "Blocked" and entry.WasInitialized)
		if startable then
			local badDep = dependenciesIn(self, entry, RUNNING_OK)
			if badDep then
				if state ~= "Blocked" then
					transition(self, entry, "Blocked", `dependency '{badDep}' is not running`)
				end
			else
				transition(self, entry, "Starting")
				entry.ActiveCleanup = entry.RunCleanup
				local ok, err = runLifecycle(entry, "Start")
				if ok then
					transition(self, entry, "Running")
				else
					entry.RunCleanup:Clean()
					transition(self, entry, "Failed", `Start: {err}`)
					self._logger:Error("Module failed to start", { Module = entry.Name, Error = err })
				end
			end
		end
	end
end

function ModuleLoader.StopAll(self: ModuleLoader)
	local order = self._order
	if order == nil then
		return
	end
	for i = #order, 1, -1 do
		local entry = order[i]
		if entry.State == "Running" then
			transition(self, entry, "Stopping")
			local ok, err = runLifecycle(entry, "Stop")
			entry.RunCleanup:Clean()
			if ok then
				transition(self, entry, "Stopped")
			else
				transition(self, entry, "Failed", `Stop: {err}`)
				self._logger:Error("Module failed to stop cleanly", { Module = entry.Name, Error = err })
			end
		end
	end
end

function ModuleLoader.DestroyAll(self: ModuleLoader)
	self:StopAll()
	local entries = self._registrationOrder
	local order: { ModuleEntry } = self._order or {}
	-- Destroy resolved modules in reverse dependency order, then everything else.
	local sequence: { ModuleEntry } = {}
	for i = #order, 1, -1 do
		table.insert(sequence, order[i])
	end
	for i = #entries, 1, -1 do
		if not table.find(sequence, entries[i]) then
			table.insert(sequence, entries[i])
		end
	end

	for _, entry in sequence do
		local state = entry.State
		if state == "Destroyed" then
			continue
		end
		if entry.WasInitialized then
			transition(self, entry, "Destroying")
			local ok, err = runLifecycle(entry, "Destroy")
			entry.RunCleanup:Clean()
			entry.LifetimeCleanup:Clean()
			if not ok then
				self._logger:Error("Module failed to destroy cleanly", { Module = entry.Name, Error = err })
			end
			transition(self, entry, "Destroyed", if ok then nil else `Destroy: {err}`)
		elseif state == "Registered" then
			-- Never resolved (framework destroyed before Start). Nothing to release.
			entry.State = "Destroyed"
		else
			transition(self, entry, "Destroyed")
		end
	end
end

-- Modules in resolved order that are currently in `state`.
function ModuleLoader.InState(self: ModuleLoader, state: ModuleState): { ModuleEntry }
	local result = {}
	for _, entry in self._registrationOrder do
		if entry.State == state then
			table.insert(result, entry)
		end
	end
	return result
end

function ModuleLoader.GetStates(self: ModuleLoader): { [string]: { State: ModuleState, Error: string?, Critical: boolean } }
	local result = {}
	for name, entry in self._entries do
		result[name] = table.freeze({ State = entry.State, Error = entry.Error, Critical = entry.Critical })
	end
	return result
end

function ModuleLoader.GetOrder(self: ModuleLoader): { string }
	local names = {}
	local order = self._order
	if order then
		for _, entry in order do
			table.insert(names, entry.Name)
		end
	end
	return names
end

return ModuleLoader
