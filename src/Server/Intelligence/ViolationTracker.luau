--!strict
--[[
	Decaying violation scores: the shared "never punish a single sample" mechanism.

	Input:  violations, each with a key (e.g. a detector name) and a weight.
	Model:  per key, a leaky integrator with half-life H:
	            score <- score * 0.5^(dt / H) + weight
	Output: Record() returns shouldReport = true when the score reaches ReportThreshold
	        and the last report for that key is at least ReportIntervalSeconds old, plus
	        the score and a confidence
	            confidence = min(MaxConfidence, 1 - exp(-score / ConfidenceScale)).

	A single violation whose weight is below the threshold can never report; isolated
	violations spaced more than a few half-lives apart decay to nothing. Memory is one
	small table per key, and keys come from code (detector names / reasons), so a
	tracker stays bounded.
]]

export type Settings = {
	HalfLifeSeconds: number,
	ReportThreshold: number,
	ReportIntervalSeconds: number,
	ConfidenceScale: number,
	MaxConfidence: number?,
}

type Entry = { score: number, updated: number, lastReport: number? }

local ViolationTracker = {}
ViolationTracker.__index = ViolationTracker

export type ViolationTracker = typeof(setmetatable(
	{} :: { _settings: Settings, _entries: { [string]: Entry } },
	ViolationTracker
))

function ViolationTracker.new(settings: Settings): ViolationTracker
	assert(settings.HalfLifeSeconds > 0, "ViolationTracker: HalfLifeSeconds must be > 0")
	assert(settings.ConfidenceScale > 0, "ViolationTracker: ConfidenceScale must be > 0")
	return setmetatable({ _settings = settings, _entries = {} }, ViolationTracker)
end

local function decayed(self: ViolationTracker, entry: Entry, now: number): number
	local elapsed = now - entry.updated
	if elapsed <= 0 then
		return entry.score
	end
	return entry.score * 0.5 ^ (elapsed / self._settings.HalfLifeSeconds)
end

function ViolationTracker.Confidence(self: ViolationTracker, score: number): number
	local settings = self._settings
	return math.min(settings.MaxConfidence or 0.95, 1 - math.exp(-score / settings.ConfidenceScale))
end

-- Adds a weighted violation. Returns (shouldReport, score, confidence).
function ViolationTracker.Record(self: ViolationTracker, key: string, weight: number, now: number): (boolean, number, number)
	if weight <= 0 then
		local current = self:Score(key, now)
		return false, current, self:Confidence(current)
	end
	local entry = self._entries[key]
	if entry == nil then
		entry = { score = 0, updated = now, lastReport = nil }
		self._entries[key] = entry
	end
	entry.score = decayed(self, entry, now) + weight
	entry.updated = now

	local settings = self._settings
	local report = entry.score >= settings.ReportThreshold
		and (entry.lastReport == nil or now - entry.lastReport >= settings.ReportIntervalSeconds)
	if report then
		entry.lastReport = now
	end
	return report, entry.score, self:Confidence(entry.score)
end

function ViolationTracker.Score(self: ViolationTracker, key: string, now: number): number
	local entry = self._entries[key]
	return if entry then decayed(self, entry, now) else 0
end

function ViolationTracker.Reset(self: ViolationTracker, key: string?)
	if key then
		self._entries[key] = nil
	else
		table.clear(self._entries)
	end
end

return ViolationTracker
