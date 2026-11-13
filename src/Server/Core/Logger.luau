--!strict
--[[
	Structured, rate-limited logger.

	Every entry has a level, a scope (e.g. "Core.Scheduler" or a module name), a constant
	message and optional structured fields. Put variable data in fields, not in the
	message: rate limiting is keyed by scope + message, so a constant message lets a flood
	of identical events collapse into one entry plus a suppressed count.

	Entries go to a sink (default: print/warn) and into a bounded ring buffer that admin
	tooling and tests can read back with GetRecent().
]]

local Types = require(script.Parent.Parent.Types)
local RateLimiter = require(script.Parent.RateLimiter)

type LogLevel = Types.LogLevel
type LogEntry = Types.LogEntry
type LogFields = Types.LogFields

local LEVEL_ORDER: { [string]: number } = { Debug = 1, Info = 2, Warn = 3, Error = 4 }
local MAX_SUPPRESSED_KEYS = 256

type SharedState = {
	level: number,
	buffer: { LogEntry },
	bufferSize: number,
	nextIndex: number,
	buffered: number,
	limiter: RateLimiter.RateLimiter,
	suppressedByKey: { [string]: number },
	suppressedKeyCount: number,
	sink: (LogEntry) -> (),
	now: () -> number,
	wall: () -> number,
	emitted: number,
	suppressed: number,
	sinkFailures: number,
}

local Logger = {}
Logger.__index = Logger

export type Logger = typeof(setmetatable({} :: { _scope: string, _shared: SharedState }, Logger))

export type LoggerOptions = {
	Level: LogLevel?,
	BufferSize: number?,
	RateLimitBurst: number?,
	RateLimitWindowSeconds: number?,
	Now: () -> number,
	Wall: (() -> number)?,
	Sink: ((LogEntry) -> ())?,
}

local function formatValue(value: any): string
	if type(value) == "string" then
		return string.format("%q", value)
	elseif type(value) == "number" then
		if value == math.floor(value) and math.abs(value) < 1e15 then
			return string.format("%d", value)
		end
		return string.format("%.4g", value)
	end
	return tostring(value)
end

-- Formats an entry as a single line: [ACF][Level][Scope] message key=value ...
function Logger.Format(entry: LogEntry): string
	local parts = { `[ACF][{entry.Level}][{entry.Scope}] {entry.Message}` }
	local fields = entry.Fields
	if fields then
		local keys = {}
		for key in fields do
			table.insert(keys, tostring(key))
		end
		table.sort(keys)
		for _, key in keys do
			table.insert(parts, `{key}={formatValue(fields[key])}`)
		end
	end
	if entry.Suppressed and entry.Suppressed > 0 then
		table.insert(parts, `(+{entry.Suppressed} suppressed)`)
	end
	return table.concat(parts, " ")
end

local function defaultSink(entry: LogEntry)
	local line = Logger.Format(entry)
	if entry.Level == "Warn" or entry.Level == "Error" then
		warn(line)
	else
		print(line)
	end
end

function Logger.new(options: LoggerOptions): Logger
	local level = options.Level or "Info"
	assert(LEVEL_ORDER[level] ~= nil, `Logger: unknown level '{tostring(level)}'`)
	local burst = options.RateLimitBurst or 20
	local window = options.RateLimitWindowSeconds or 10
	local shared: SharedState = {
		level = LEVEL_ORDER[level],
		buffer = {},
		bufferSize = options.BufferSize or 500,
		nextIndex = 1,
		buffered = 0,
		limiter = RateLimiter.new(burst, burst / window, options.Now, 512),
		suppressedByKey = {},
		suppressedKeyCount = 0,
		sink = options.Sink or defaultSink,
		now = options.Now,
		wall = options.Wall or os.time,
		emitted = 0,
		suppressed = 0,
		sinkFailures = 0,
	}
	return setmetatable({ _scope = "Core", _shared = shared }, Logger)
end

-- Returns a logger that shares buffer, level and rate limits but tags entries with a
-- different scope. Scope("X") on the root logger yields scope "X".
function Logger.Scope(self: Logger, name: string): Logger
	return setmetatable({ _scope = name, _shared = self._shared }, Logger)
end

function Logger.GetScope(self: Logger): string
	return self._scope
end

function Logger.SetLevel(self: Logger, level: LogLevel)
	assert(LEVEL_ORDER[level] ~= nil, `Logger: unknown level '{tostring(level)}'`)
	self._shared.level = LEVEL_ORDER[level]
end

function Logger.IsEnabled(self: Logger, level: LogLevel): boolean
	return LEVEL_ORDER[level] >= self._shared.level
end

function Logger.Log(self: Logger, level: LogLevel, message: string, fields: LogFields?)
	local shared = self._shared
	local order = LEVEL_ORDER[level]
	if order == nil or order < shared.level then
		return
	end

	local key = self._scope .. "|" .. message
	if not shared.limiter:Allow(key) then
		shared.suppressed += 1
		local count = shared.suppressedByKey[key]
		if count then
			shared.suppressedByKey[key] = count + 1
		elseif shared.suppressedKeyCount < MAX_SUPPRESSED_KEYS then
			shared.suppressedByKey[key] = 1
			shared.suppressedKeyCount += 1
		end
		return
	end

	local suppressedSince = shared.suppressedByKey[key]
	if suppressedSince then
		shared.suppressedByKey[key] = nil
		shared.suppressedKeyCount -= 1
	end

	local entry: LogEntry = table.freeze({
		Time = shared.now(),
		WallTime = shared.wall(),
		Level = level,
		Scope = self._scope,
		Message = message,
		Fields = if fields then table.freeze(table.clone(fields)) else nil,
		Suppressed = suppressedSince,
	})

	shared.buffer[shared.nextIndex] = entry
	shared.nextIndex = (shared.nextIndex % shared.bufferSize) + 1
	shared.buffered = math.min(shared.buffered + 1, shared.bufferSize)
	shared.emitted += 1

	local ok = pcall(shared.sink, entry)
	if not ok then
		shared.sinkFailures += 1
	end
end

function Logger.Debug(self: Logger, message: string, fields: LogFields?)
	self:Log("Debug", message, fields)
end

function Logger.Info(self: Logger, message: string, fields: LogFields?)
	self:Log("Info", message, fields)
end

function Logger.Warn(self: Logger, message: string, fields: LogFields?)
	self:Log("Warn", message, fields)
end

function Logger.Error(self: Logger, message: string, fields: LogFields?)
	self:Log("Error", message, fields)
end

-- Returns up to `count` most recent entries, oldest first.
function Logger.GetRecent(self: Logger, count: number?): { LogEntry }
	local shared = self._shared
	local n = math.min(count or shared.buffered, shared.buffered)
	local result = table.create(n)
	-- nextIndex points at the slot after the newest entry.
	local start = shared.nextIndex - n
	for i = 0, n - 1 do
		local index = ((start + i - 1) % shared.bufferSize) + 1
		table.insert(result, shared.buffer[index])
	end
	return result
end

function Logger.GetStats(self: Logger): { Emitted: number, Suppressed: number, Buffered: number, SinkFailures: number }
	local shared = self._shared
	return {
		Emitted = shared.emitted,
		Suppressed = shared.suppressed,
		Buffered = shared.buffered,
		SinkFailures = shared.sinkFailures,
	}
end

return Logger
