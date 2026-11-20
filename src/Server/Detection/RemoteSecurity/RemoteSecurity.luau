--!strict
--[[
	RemoteSecurity: server-side protection for RemoteEvents and RemoteFunctions.

	Developers describe each remote once:

		ACF:ProtectEvent(remotes.BuyItem, {
			Arguments = { V.string({ MaxLength = 32 }), V.integer({ Min = 1, Max = 99 }) },
			RateLimit = { Burst = 5, PerSecond = 1 },
			Cooldown = 0.25,
			Permission = ACF.Permissions.groupRank(123, 10),
			Ownership = nil,
			Idempotency = nil,
			Handler = function(player, itemId, quantity) ... end,
		})

	Pipeline per request, cheapest checks first; the first failure rejects:
	  1. active session            (no_session, not suspicious)
	  2. rate limit                (rate_limited)
	  2b. enforcement restriction  (restricted, not suspicious; spec.Restrict only):
	      rejected while Enforcement restricts the player for that tag (Phase 7)
	  3. argument count and schema (invalid_arguments)
	  4. character present         (no_character, not suspicious; RequireCharacter only)
	  5. cooldown since last accept(cooldown)
	  6. Permission check          (permission_denied)
	  7. Ownership check           (ownership_denied)
	  8. duplicate transaction id  (duplicate_transaction; Idempotency only)
	  9. Handler(player, ...)      errors are logged, never treated as player behaviour

	Fail closed: while the module is not Running, events are ignored and functions
	return RejectResponse. Rejected function calls return RejectResponse (default nil).

	Suspicion model (do not treat one bad request as cheating):
	  Each (player, remote, reason) keeps a score that decays exponentially with
	  half-life H. A rejection adds the reason's weight w. When the score reaches the
	  report threshold T (and the last report for that pair is older than the report
	  interval), a detection is reported with
	      Confidence = min(0.95, 1 - exp(-score / ConfidenceScale)).
	  With the defaults (w = 2 for invalid arguments, T = 6, H = 30 s) a single malformed
	  request never reports; three in quick succession do. Weights are configurable per
	  reason and can be overridden per remote.
]]

local Configuration = require(script.Parent.Parent.Parent.Core.Configuration)
local RateLimiter = require(script.Parent.Parent.Parent.Core.RateLimiter)
local ViolationTracker = require(script.Parent.Parent.Parent.Intelligence.ViolationTracker)
local Validators = require(script.Parent.Validators)

local S = Configuration.Schema

local MODULE_NAME = "RemoteSecurity"
local STATE_KEY = "RemoteSecurity.State"

export type Reason =
	"no_session"
	| "rate_limited"
	| "invalid_arguments"
	| "no_character"
	| "cooldown"
	| "permission_denied"
	| "ownership_denied"
	| "duplicate_transaction"
	| "restricted"
	| "not_running"

-- Reason -> configuration key for weights/severity, and reported detection Kind.
local REASON_INFO: { [string]: { Key: string, Kind: string }? } = {
	rate_limited = { Key = "RateLimited", Kind = "RemoteRateLimitExceeded" },
	invalid_arguments = { Key = "InvalidArguments", Kind = "RemoteInvalidArguments" },
	cooldown = { Key = "Cooldown", Kind = "RemoteCooldownViolation" },
	permission_denied = { Key = "PermissionDenied", Kind = "RemotePermissionDenied" },
	ownership_denied = { Key = "OwnershipDenied", Kind = "RemoteOwnershipViolation" },
	duplicate_transaction = { Key = "Duplicate", Kind = "RemoteDuplicateTransaction" },
}

local WEIGHT_KEYS = { "RateLimited", "InvalidArguments", "Cooldown", "PermissionDenied", "OwnershipDenied", "Duplicate" }

local SPEC_KEYS = {
	Name = true,
	Arguments = true,
	Handler = true,
	RateLimit = true,
	Cooldown = true,
	Permission = true,
	Ownership = true,
	Idempotency = true,
	RequireCharacter = true,
	SuspicionWeights = true,
	RejectResponse = true,
	Restrict = true,
}

local function weightTable(defaults: { [string]: number }, severityMode: boolean)
	local fields = {}
	for _, key in WEIGHT_KEYS do
		fields[key] = S.Number(defaults[key], { Min = 0, Max = if severityMode then 100 else 1000 })
	end
	return S.Table(fields)
end

local CONFIG_SCHEMA = S.Table({
	DefaultRateLimit = S.Table({
		Burst = S.Number(10, { Min = 1, Max = 10000, Integer = true }),
		PerSecond = S.Number(5, { Min = 0.01, Max = 1000 }),
	}),
	Suspicion = S.Table({
		HalfLifeSeconds = S.Number(30, { Min = 1, Max = 3600 }),
		ReportThreshold = S.Number(6, { Min = 0.1, Max = 10000 }),
		ReportIntervalSeconds = S.Number(10, { Min = 0, Max = 3600 }),
		ConfidenceScale = S.Number(10, { Min = 0.1, Max = 10000 }),
		Weights = weightTable({
			RateLimited = 1,
			InvalidArguments = 2,
			Cooldown = 0.5,
			PermissionDenied = 3,
			OwnershipDenied = 3,
			Duplicate = 0.5,
		}, false),
		Severity = weightTable({
			RateLimited = 10,
			InvalidArguments = 15,
			Cooldown = 5,
			PermissionDenied = 20,
			OwnershipDenied = 25,
			Duplicate = 5,
		}, true),
	}),
})

type Spec = {
	Name: string,
	Arguments: { Validators.Validator },
	Handler: (...any) -> ...any,
	RateLimit: { Burst: number, PerSecond: number }?,
	Cooldown: number,
	Permission: ((...any) -> (boolean, string?))?,
	Ownership: ((...any) -> (boolean, string?))?,
	Idempotency: { Argument: number, WindowSeconds: number, MaxEntries: number }?,
	RequireCharacter: boolean,
	SuspicionWeights: { [string]: number },
	RejectResponse: any,
	-- Enforcement tag (a risk group such as "Economy"), or true for any restriction.
	Restrict: (string | boolean)?,
}

type Stats = {
	Accepted: number,
	Rejected: { [string]: number },
	HandlerErrors: number,
	Reports: number,
}

type Protection = {
	Name: string,
	Remote: any,
	Kind: "Event" | "Function",
	Spec: Spec,
	Stats: Stats,
	Connection: any?,
	Active: boolean,
}

type RemoteState = {
	limiter: RateLimiter.RateLimiter,
	lastAccepted: number?,
	seenIds: { [any]: number },
	idOrder: { any },
	suspicion: ViolationTracker.ViolationTracker,
}

local RemoteSecurity = {}
RemoteSecurity.Name = MODULE_NAME
RemoteSecurity.ConfigSchema = CONFIG_SCHEMA

local function isA(remote: any, className: string): boolean
	local ok, result = pcall(function()
		return remote:IsA(className)
	end)
	return ok and result == true
end

local function remoteName(remote: any): string
	local ok, name = pcall(function()
		return remote.Name
	end)
	return if ok and type(name) == "string" then name else "Remote"
end

-- Validates a developer-supplied spec. Raises (level 3 = the ProtectX caller's caller)
-- on any problem, listing the offending field.
local function normalizeSpec(remote: any, raw: any, kind: "Event" | "Function"): Spec
	local function fail(message: string): never
		error(`ACF RemoteSecurity: {message}`, 4)
	end
	if type(raw) ~= "table" then
		fail("protection spec must be a table")
	end
	for key in raw do
		if not SPEC_KEYS[key] then
			fail(`unknown spec field '{tostring(key)}'`)
		end
	end
	if raw.RejectResponse ~= nil and kind ~= "Function" then
		fail("RejectResponse only applies to RemoteFunctions")
	end

	local name = raw.Name or remoteName(remote)
	if type(name) ~= "string" or #name == 0 or #name > 64 then
		fail("Name must be a non-empty string of at most 64 characters")
	end
	if type(raw.Handler) ~= "function" then
		fail(`'{name}': Handler function is required`)
	end
	local arguments = raw.Arguments
	if type(arguments) ~= "table" then
		fail(`'{name}': Arguments must be an array of validators (use {"{}"} for none)`)
	end
	local argCount = 0
	for key in arguments do
		argCount += 1
		if type(key) ~= "number" then
			fail(`'{name}': Arguments must be an array`)
		end
	end
	for i = 1, argCount do
		if not Validators.isValidator(arguments[i]) then
			fail(`'{name}': Arguments[{i}] is not a validator`)
		end
	end

	local rateLimit = raw.RateLimit
	if rateLimit ~= nil then
		if type(rateLimit) ~= "table" or type(rateLimit.Burst) ~= "number" or type(rateLimit.PerSecond) ~= "number" then
			fail(`'{name}': RateLimit must be {"{ Burst = number, PerSecond = number }"}`)
		end
		if rateLimit.Burst < 1 or rateLimit.PerSecond <= 0 then
			fail(`'{name}': RateLimit needs Burst >= 1 and PerSecond > 0`)
		end
	end

	local cooldown = raw.Cooldown or 0
	if type(cooldown) ~= "number" or cooldown < 0 or cooldown ~= cooldown then
		fail(`'{name}': Cooldown must be a non-negative number`)
	end
	if raw.Permission ~= nil and type(raw.Permission) ~= "function" then
		fail(`'{name}': Permission must be a function`)
	end
	if raw.Ownership ~= nil and type(raw.Ownership) ~= "function" then
		fail(`'{name}': Ownership must be a function`)
	end
	local restrict = raw.Restrict
	if restrict ~= nil and restrict ~= true and (type(restrict) ~= "string" or #restrict == 0 or #restrict > 64) then
		fail(`'{name}': Restrict must be a tag string (e.g. "Economy") or true`)
	end
	if raw.RequireCharacter ~= nil and type(raw.RequireCharacter) ~= "boolean" then
		fail(`'{name}': RequireCharacter must be a boolean`)
	end

	local idempotency = nil
	if raw.Idempotency ~= nil then
		local idem = raw.Idempotency
		if type(idem) ~= "table" or type(idem.Argument) ~= "number" then
			fail(`'{name}': Idempotency must be {"{ Argument = index, WindowSeconds?, MaxEntries? }"}`)
		end
		if idem.Argument < 1 or idem.Argument > argCount or idem.Argument ~= math.floor(idem.Argument) then
			fail(`'{name}': Idempotency.Argument must index one of the Arguments`)
		end
		local kindName = arguments[idem.Argument].Kind
		if kindName ~= "string" and kindName ~= "number" then
			fail(`'{name}': the transaction id argument must be validated as a string or number`)
		end
		local window = idem.WindowSeconds or 60
		local maxEntries = idem.MaxEntries or 64
		if type(window) ~= "number" or window <= 0 then
			fail(`'{name}': Idempotency.WindowSeconds must be > 0`)
		end
		if type(maxEntries) ~= "number" or maxEntries < 1 or maxEntries > 4096 then
			fail(`'{name}': Idempotency.MaxEntries must be between 1 and 4096`)
		end
		idempotency = { Argument = idem.Argument, WindowSeconds = window, MaxEntries = math.floor(maxEntries) }
	end

	local weights = {}
	if raw.SuspicionWeights ~= nil then
		if type(raw.SuspicionWeights) ~= "table" then
			fail(`'{name}': SuspicionWeights must be a table`)
		end
		for key, value in raw.SuspicionWeights do
			if not table.find(WEIGHT_KEYS, key) then
				fail(`'{name}': unknown SuspicionWeights key '{tostring(key)}'`)
			end
			if type(value) ~= "number" or value < 0 then
				fail(`'{name}': SuspicionWeights.{key} must be a non-negative number`)
			end
			weights[key] = value
		end
	end

	return table.freeze({
		Name = name,
		Arguments = table.freeze(table.clone(arguments)),
		Handler = raw.Handler,
		RateLimit = if rateLimit then table.freeze({ Burst = rateLimit.Burst, PerSecond = rateLimit.PerSecond }) else nil,
		Cooldown = cooldown,
		Permission = raw.Permission,
		Ownership = raw.Ownership,
		Idempotency = if idempotency then table.freeze(idempotency) else nil,
		RequireCharacter = raw.RequireCharacter == true,
		SuspicionWeights = table.freeze(weights),
		RejectResponse = raw.RejectResponse,
		Restrict = restrict,
	}) :: any
end

function RemoteSecurity.new()
	local module: any = {
		Name = MODULE_NAME,
		Version = "1.0.0",
		Category = "Remote",
		EnabledByDefault = true,
		ConfigSchema = CONFIG_SCHEMA,
	}

	local context: any = nil
	local running = false
	local destroyed = false
	local protections: { [string]: Protection } = {}
	local byRemote: { [any]: Protection } = {}

	-- Per-session state ----------------------------------------------------------------

	local function remoteState(session: any, protection: Protection): RemoteState
		local all = session:GetState(STATE_KEY, function()
			return {}
		end)
		local state = all[protection.Name]
		if state == nil then
			local limit = protection.Spec.RateLimit or context.Config.DefaultRateLimit
			state = {
				limiter = RateLimiter.new(limit.Burst, limit.PerSecond, context.Clock.Now, 1),
				lastAccepted = nil,
				seenIds = {},
				idOrder = {},
				suspicion = ViolationTracker.new(context.Config.Suspicion),
			}
			all[protection.Name] = state
		end
		return state
	end

	local function recordSuspicion(protection: Protection, session: any, state: RemoteState, reason: string, problem: string?)
		local info = REASON_INFO[reason]
		if info == nil then
			return
		end
		local settings = context.Config.Suspicion
		local weight = protection.Spec.SuspicionWeights[info.Key] or settings.Weights[info.Key]
		if weight <= 0 then
			return
		end
		local shouldReport, score, confidence = state.suspicion:Record(reason, weight, context.Clock.Now())
		if not shouldReport then
			return
		end
		protection.Stats.Reports += 1
		context:Report(session, {
			Kind = info.Kind,
			Severity = settings.Severity[info.Key],
			Confidence = confidence,
			Details = {
				Remote = protection.Name,
				Reason = reason,
				Score = math.floor(score * 100) / 100,
				Threshold = settings.ReportThreshold,
				HalfLifeSeconds = settings.HalfLifeSeconds,
				LastProblem = problem,
			},
		})
	end

	local function reject(protection: Protection, session: any?, state: RemoteState?, reason: string, problem: string?): false
		local rejected = protection.Stats.Rejected
		rejected[reason] = (rejected[reason] or 0) + 1
		if context then
			-- Guarded so floods of rejections cost no allocations when Debug is off.
			if context.Logger:IsEnabled("Debug") then
				context.Logger:Debug("Remote request rejected", {
					Remote = protection.Name,
					Reason = reason,
					Problem = problem,
					UserId = if session then session.UserId else nil,
				})
			end
			if session and state then
				recordSuspicion(protection, session, state, reason, problem)
			end
		end
		return false
	end

	-- Runs a Permission/Ownership check. Returns nil when it passes (or is absent),
	-- otherwise the denial text ("" when the check gave no reason).
	local function runPolicy(protection: Protection, fn: ((...any) -> (boolean, string?))?, reason: string, player: any, args: any): string?
		if fn == nil then
			return nil
		end
		local ok, allowed, reasonText = pcall(fn, player, table.unpack(args, 1, args.n))
		if not ok then
			context.Logger:Error("Remote policy check errored; request denied", {
				Remote = protection.Name,
				Check = reason,
				Error = tostring(allowed),
			})
			return "policy check errored"
		elseif not allowed then
			return if type(reasonText) == "string" then reasonText else ""
		end
		return nil
	end

	-- Runs checks 1-8. Returns (true, packedArgs) or (false).
	local function admit(protection: Protection, player: any, ...: any): (boolean, any)
		if not running then
			return reject(protection, nil, nil, "not_running")
		end
		local session = context.Players:GetSession(player)
		if session == nil then
			return reject(protection, nil, nil, "no_session")
		end
		local state = remoteState(session, protection)
		local spec = protection.Spec

		if not state.limiter:Allow("r") then
			return reject(protection, session, state, "rate_limited")
		end

		-- An enforcement decision, not player behaviour: no suspicion is recorded.
		if spec.Restrict ~= nil and context.Enforcement:IsRestricted(session, spec.Restrict, protection.Name) then
			return reject(protection, nil, nil, "restricted")
		end

		local count = select("#", ...)
		if count > #spec.Arguments then
			return reject(protection, session, state, "invalid_arguments", `expected at most {#spec.Arguments} arguments`)
		end
		local args = table.pack(...)
		for i, validator in spec.Arguments do
			local ok, valid, problem = pcall(validator.Check, args[i], `arg{i}`)
			if not ok then
				return reject(protection, session, state, "invalid_arguments", `arg{i}: validator error`)
			elseif not valid then
				return reject(protection, session, state, "invalid_arguments", problem)
			end
		end
		args.n = #spec.Arguments

		if spec.RequireCharacter and session.Character == nil then
			return reject(protection, session, state, "no_character")
		end

		local now = context.Clock.Now()
		if spec.Cooldown > 0 and state.lastAccepted ~= nil and now - state.lastAccepted < spec.Cooldown then
			return reject(protection, session, state, "cooldown")
		end

		local problem = runPolicy(protection, spec.Permission, "permission_denied", player, args)
		if problem then
			return reject(protection, session, state, "permission_denied", if problem == "" then nil else problem)
		end
		problem = runPolicy(protection, spec.Ownership, "ownership_denied", player, args)
		if problem then
			return reject(protection, session, state, "ownership_denied", if problem == "" then nil else problem)
		end

		local idem = spec.Idempotency
		if idem then
			local id = args[idem.Argument]
			local seenAt = state.seenIds[id]
			if seenAt ~= nil and now - seenAt <= idem.WindowSeconds then
				return reject(protection, session, state, "duplicate_transaction")
			end
			-- Expire old ids and enforce the cap (oldest first).
			local order = state.idOrder
			while #order > 0 and (now - (state.seenIds[order[1]] or -math.huge) > idem.WindowSeconds or #order >= idem.MaxEntries) do
				local oldest = table.remove(order, 1)
				state.seenIds[oldest] = nil
			end
			if seenAt ~= nil then
				local index = table.find(order, id)
				if index then
					table.remove(order, index)
				end
			end
			state.seenIds[id] = now
			table.insert(order, id)
		end

		state.lastAccepted = now
		protection.Stats.Accepted += 1
		return true, args
	end

	local function onEvent(protection: Protection, player: any, ...: any)
		local admitted, args = admit(protection, player, ...)
		if not admitted then
			return
		end
		local ok, err = pcall(protection.Spec.Handler, player, table.unpack(args, 1, args.n))
		if not ok then
			protection.Stats.HandlerErrors += 1
			context.Logger:Error("Remote handler errored", { Remote = protection.Name, Error = tostring(err) })
		end
	end

	local function onInvoke(protection: Protection, player: any, ...: any): ...any
		local admitted, args = admit(protection, player, ...)
		if not admitted then
			return protection.Spec.RejectResponse
		end
		local results = table.pack(pcall(protection.Spec.Handler, player, table.unpack(args, 1, args.n)))
		if not results[1] then
			protection.Stats.HandlerErrors += 1
			context.Logger:Error("Remote handler errored", { Remote = protection.Name, Error = tostring(results[2]) })
			return protection.Spec.RejectResponse
		end
		return table.unpack(results, 2, results.n)
	end

	local function connect(protection: Protection)
		if protection.Kind == "Event" then
			if protection.Connection == nil then
				protection.Connection = protection.Remote.OnServerEvent:Connect(function(player, ...)
					onEvent(protection, player, ...)
				end)
			end
		else
			protection.Remote.OnServerInvoke = function(player, ...)
				return onInvoke(protection, player, ...)
			end
		end
	end

	local function disconnect(protection: Protection, closeFunction: boolean)
		if protection.Kind == "Event" then
			local connection = protection.Connection
			if connection then
				connection:Disconnect()
				protection.Connection = nil
			end
		elseif closeFunction then
			-- Fail closed without leaving clients yielding forever.
			local response = protection.Spec.RejectResponse
			protection.Remote.OnServerInvoke = function()
				return response
			end
		else
			protection.Remote.OnServerInvoke = nil
		end
	end

	local function protect(remote: any, rawSpec: any, kind: "Event" | "Function")
		if destroyed then
			error("ACF RemoteSecurity: module has been destroyed", 3)
		end
		if remote == nil then
			error("ACF RemoteSecurity: remote is nil", 3)
		end
		if kind == "Event" then
			if not (isA(remote, "RemoteEvent") or isA(remote, "UnreliableRemoteEvent")) then
				error("ACF RemoteSecurity: ProtectEvent expects a RemoteEvent or UnreliableRemoteEvent", 3)
			end
		elseif not isA(remote, "RemoteFunction") then
			error("ACF RemoteSecurity: ProtectFunction expects a RemoteFunction", 3)
		end
		if byRemote[remote] then
			error(`ACF RemoteSecurity: remote '{remoteName(remote)}' is already protected`, 3)
		end
		local spec = normalizeSpec(remote, rawSpec, kind)
		if protections[spec.Name] then
			error(`ACF RemoteSecurity: a protection named '{spec.Name}' already exists; set a unique Name`, 3)
		end

		local protection: Protection = {
			Name = spec.Name,
			Remote = remote,
			Kind = kind,
			Spec = spec,
			Stats = { Accepted = 0, Rejected = {}, HandlerErrors = 0, Reports = 0 },
			Connection = nil,
			Active = true,
		}
		protections[spec.Name] = protection
		byRemote[remote] = protection
		if running then
			connect(protection)
		elseif kind == "Function" then
			disconnect(protection, true)
		end

		return table.freeze({
			Name = spec.Name,
			Unprotect = function()
				if not protection.Active then
					return
				end
				protection.Active = false
				disconnect(protection, false)
				protections[protection.Name] = nil
				byRemote[remote] = nil
			end,
		})
	end

	-- Public surface ------------------------------------------------------------------

	-- Protects a RemoteEvent or UnreliableRemoteEvent. Returns { Name, Unprotect() }.
	function module:ProtectEvent(remote: any, spec: any)
		return protect(remote, spec, "Event")
	end

	-- Protects a RemoteFunction (server side; the server never invokes the client).
	function module:ProtectFunction(remote: any, spec: any)
		return protect(remote, spec, "Function")
	end

	function module:IsProtected(remote: any): boolean
		return byRemote[remote] ~= nil
	end

	-- Remote instances under `root` that have no protection. Use during development to
	-- find remotes that bypass validation.
	function module:FindUnprotected(root: any): { any }
		local result = {}
		for _, descendant in root:GetDescendants() do
			local isRemote = isA(descendant, "RemoteEvent")
				or isA(descendant, "UnreliableRemoteEvent")
				or isA(descendant, "RemoteFunction")
			if isRemote and byRemote[descendant] == nil then
				table.insert(result, descendant)
			end
		end
		return result
	end

	function module:GetStats(): { [string]: any }
		local result = {}
		for name, protection in protections do
			result[name] = {
				Kind = protection.Kind,
				Accepted = protection.Stats.Accepted,
				Rejected = table.clone(protection.Stats.Rejected),
				HandlerErrors = protection.Stats.HandlerErrors,
				Reports = protection.Stats.Reports,
			}
		end
		return result
	end

	-- Lifecycle -----------------------------------------------------------------------

	function module:Initialize(ctx)
		context = ctx
	end

	function module:Start()
		running = true
		for _, protection in protections do
			connect(protection)
		end
		context.Logger:Info("Remote protection active", { Remotes = #self:GetProtectedNames() })
	end

	function module:Stop()
		running = false
		for _, protection in protections do
			disconnect(protection, true)
		end
	end

	function module:Destroy()
		running = false
		destroyed = true
		for _, protection in protections do
			disconnect(protection, true)
		end
		table.clear(protections)
		table.clear(byRemote)
	end

	function module:GetProtectedNames(): { string }
		local names = {}
		for name in protections do
			table.insert(names, name)
		end
		table.sort(names)
		return names
	end

	return module
end

return RemoteSecurity
