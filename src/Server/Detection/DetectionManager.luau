--!strict
--[[
	Detection ingestion pipeline.

	Modules call context:Report(target, input). The context binds the detector's name
	and category, so a module cannot report under another module's identity. This
	manager then:

	  1. checks the reporting module is Running,
	  2. resolves the target to an active session,
	  3. validates the input schema (Kind, Severity 0..100, Confidence 0..1),
	  4. applies a per-(session, detector) token bucket so a misbehaving detector cannot
	     exhaust memory or CPU,
	  5. sanitises Details (string keys, bounded size and depth, Instances converted to
	     their full names so destroyed parts are not kept alive),
	  6. builds a frozen DetectionEvent, records it as evidence, and publishes
	     DetectionReported.

	Rejections return (false, reason) where reason is one of the REASONS values; they are
	never thrown.
]]

local EventBus = require(script.Parent.Parent.Core.EventBus)
local Logger = require(script.Parent.Parent.Core.Logger)
local PlayerRegistry = require(script.Parent.Parent.Core.PlayerRegistry)
local RateLimiter = require(script.Parent.Parent.Core.RateLimiter)
local Topics = require(script.Parent.Parent.Core.Topics)
local EvidenceManager = require(script.Parent.Parent.Intelligence.EvidenceManager)
local Types = require(script.Parent.Parent.Types)

type DetectionEvent = Types.DetectionEvent

local REASONS = table.freeze({
	NotRunning = "module_not_running",
	NoSession = "no_session",
	InvalidInput = "invalid_input",
	RateLimited = "rate_limited",
})

local MAX_KIND_LENGTH = 64
local MAX_KEY_LENGTH = 64
local MAX_DETAIL_DEPTH = 2
local LIMITER_STATE_KEY = "ACF.DetectionLimiter"

local PRIMITIVE_TYPES = {
	number = true,
	boolean = true,
	Vector3 = true,
	Vector2 = true,
	CFrame = true,
	EnumItem = true,
	Color3 = true,
	UDim2 = true,
}

export type DetectionSettings = {
	ReportsPerSecond: number,
	ReportBurst: number,
	MaxDetailKeys: number,
	MaxDetailStringLength: number,
}

export type ReportSource = {
	Name: string,
	Category: Types.DetectionCategory,
	State: Types.ModuleState,
}

local DetectionManager = {}
DetectionManager.__index = DetectionManager
DetectionManager.Reasons = REASONS

export type DetectionManager = typeof(setmetatable(
	{} :: {
		_registry: PlayerRegistry.PlayerRegistry,
		_evidence: EvidenceManager.EvidenceManager,
		_bus: EventBus.EventBus,
		_logger: Logger.Logger,
		_clock: Types.Clock,
		_generateId: () -> string,
		_settings: DetectionSettings,
		_accepted: number,
		_rejected: { [string]: number },
	},
	DetectionManager
))

export type DetectionManagerOptions = {
	Registry: PlayerRegistry.PlayerRegistry,
	Evidence: EvidenceManager.EvidenceManager,
	Bus: EventBus.EventBus,
	Logger: Logger.Logger,
	Clock: Types.Clock,
	GenerateId: () -> string,
	Settings: DetectionSettings,
}

function DetectionManager.new(options: DetectionManagerOptions): DetectionManager
	return setmetatable({
		_registry = options.Registry,
		_evidence = options.Evidence,
		_bus = options.Bus,
		_logger = options.Logger,
		_clock = options.Clock,
		_generateId = options.GenerateId,
		_settings = options.Settings,
		_accepted = 0,
		_rejected = {},
	}, DetectionManager)
end

local function isFinite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local sanitize: (value: any, depth: number, settings: DetectionSettings) -> any

local function sanitizeTable(input: { [any]: any }, depth: number, settings: DetectionSettings): { [string]: any }
	local output = {}
	local keys = 0
	for key, value in input do
		if keys >= settings.MaxDetailKeys then
			output["_truncated"] = true
			break
		end
		local keyString = if type(key) == "string" then key elseif type(key) == "number" then tostring(key) else nil
		if keyString and #keyString <= MAX_KEY_LENGTH then
			local clean = sanitize(value, depth, settings)
			if clean ~= nil then
				output[keyString] = clean
				keys += 1
			end
		end
	end
	return table.freeze(output)
end

sanitize = function(value: any, depth: number, settings: DetectionSettings): any
	local kind = typeof(value)
	if kind == "string" then
		if #value > settings.MaxDetailStringLength then
			return string.sub(value, 1, settings.MaxDetailStringLength) .. "..."
		end
		return value
	elseif kind == "number" then
		return if isFinite(value) then value else tostring(value)
	elseif PRIMITIVE_TYPES[kind] then
		return value
	elseif kind == "Instance" then
		local ok, name = pcall(function()
			return value:GetFullName()
		end)
		return if ok then name else "<Instance>"
	elseif kind == "table" then
		if depth >= MAX_DETAIL_DEPTH then
			return "<table>"
		end
		return sanitizeTable(value, depth + 1, settings)
	end
	return nil -- functions, threads, userdata: dropped
end

local function validateInput(input: any): string?
	if type(input) ~= "table" then
		return "input must be a table"
	end
	local kind = input.Kind
	if type(kind) ~= "string" or #kind == 0 or #kind > MAX_KIND_LENGTH then
		return `Kind must be a non-empty string of at most {MAX_KIND_LENGTH} characters`
	end
	if not isFinite(input.Severity) or input.Severity < 0 or input.Severity > 100 then
		return "Severity must be a number between 0 and 100"
	end
	if not isFinite(input.Confidence) or input.Confidence < 0 or input.Confidence > 1 then
		return "Confidence must be a number between 0 and 1"
	end
	if input.Details ~= nil and type(input.Details) ~= "table" then
		return "Details must be a table when provided"
	end
	return nil
end

local function reject(self: DetectionManager, reason: string, source: ReportSource, extra: string?): (boolean, string)
	self._rejected[reason] = (self._rejected[reason] or 0) + 1
	if reason == REASONS.InvalidInput then
		-- Invalid input is a module bug, not player behaviour: make it visible.
		self._logger:Warn("Detection report rejected: invalid input", { Detector = source.Name, Problem = extra })
	elseif reason == REASONS.RateLimited then
		self._logger:Warn("Detection reports rate limited", { Detector = source.Name })
	else
		self._logger:Debug("Detection report rejected", { Detector = source.Name, Reason = reason })
	end
	return false, if extra then `{reason}: {extra}` else reason
end

function DetectionManager.Report(self: DetectionManager, source: ReportSource, target: any, input: Types.DetectionInput): (boolean, string)
	if source.State ~= "Running" then
		return reject(self, REASONS.NotRunning, source)
	end
	local problem = validateInput(input)
	if problem then
		return reject(self, REASONS.InvalidInput, source, problem)
	end
	local session = self._registry:GetSession(target)
	if session == nil then
		return reject(self, REASONS.NoSession, source)
	end

	local settings = self._settings
	local limiter = session:GetState(LIMITER_STATE_KEY, function()
		return RateLimiter.new(settings.ReportBurst, settings.ReportsPerSecond, self._clock.Now, 256)
	end)
	if not limiter:Allow(source.Name) then
		return reject(self, REASONS.RateLimited, source)
	end

	local details = if input.Details then sanitizeTable(input.Details, 1, settings) else table.freeze({})
	local event: DetectionEvent = table.freeze({
		Id = self._generateId(),
		Detector = source.Name,
		Category = source.Category,
		Kind = input.Kind,
		UserId = session.UserId,
		SessionId = session.SessionId,
		Severity = input.Severity,
		Confidence = input.Confidence,
		Time = self._clock.Now(),
		WallTime = self._clock.Wall(),
		Details = details,
	})

	local record, isNew = self._evidence:Record(event)
	self._accepted += 1
	self._logger:Debug("Detection recorded", {
		Detector = event.Detector,
		Kind = event.Kind,
		UserId = event.UserId,
		Severity = event.Severity,
		Confidence = event.Confidence,
	})
	self._bus:Publish(Topics.DetectionReported, table.freeze({ Event = event, Record = record, IsNewRecord = isNew }))
	return true, event.Id
end

function DetectionManager.GetStats(self: DetectionManager): { Accepted: number, Rejected: { [string]: number } }
	return { Accepted = self._accepted, Rejected = table.clone(self._rejected) }
end

return DetectionManager
