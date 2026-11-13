--!strict
--[[
	Bounded, per-user evidence store.

	Evidence is keyed by UserId (not SessionId), so leaving and rejoining the same server
	does not wipe a player's recent evidence. Each record keeps the SessionId it was
	first seen in.

	Duplicate suppression: a detection with the same (Detector, Kind) as an existing
	record whose LastSeen is within DuplicateWindowSeconds is merged into that record
	(Count += 1, Severity/Confidence take the maximum, Details take the latest) instead of
	creating a new record. A flood of one signal therefore costs O(1) memory.

	Bounds: at most MaxRecordsPerPlayer records per user (the least recently seen record
	is evicted), and records not seen for RetentionSeconds are pruned. A user's store is
	dropped once it is empty.

	This module stores and summarises evidence. It does not score risk (Phase 6) or
	enforce anything (Phase 7). Persistence across servers is Phase 6.
]]

local Logger = require(script.Parent.Parent.Core.Logger)
local Types = require(script.Parent.Parent.Types)

type DetectionEvent = Types.DetectionEvent
type EvidenceRecord = Types.EvidenceRecord

type MutableRecord = {
	Id: string,
	UserId: number,
	SessionId: string,
	Detector: string,
	Category: Types.DetectionCategory,
	Kind: string,
	Severity: number,
	Confidence: number,
	Count: number,
	FirstSeen: number,
	LastSeen: number,
	FirstWallTime: number,
	LastWallTime: number,
	FirstEventId: string,
	Details: { [string]: any },
}

type Store = {
	records: { MutableRecord },
	-- (Detector|Kind) -> newest record with that key
	latest: { [string]: MutableRecord },
	totalDetections: number,
	merged: number,
	evicted: number,
	expired: number,
}

export type EvidenceSummary = {
	UserId: number,
	Records: number,
	TotalDetections: number,
	Merged: number,
	Evicted: number,
	Expired: number,
	ByCategory: { [string]: number },
}

export type EvidenceSettings = {
	MaxRecordsPerPlayer: number,
	RetentionSeconds: number,
	DuplicateWindowSeconds: number,
}

local EvidenceManager = {}
EvidenceManager.__index = EvidenceManager

export type EvidenceManager = typeof(setmetatable(
	{} :: {
		_clock: Types.Clock,
		_logger: Logger.Logger,
		_generateId: () -> string,
		_settings: EvidenceSettings,
		_stores: { [number]: Store },
	},
	EvidenceManager
))

export type EvidenceManagerOptions = {
	Clock: Types.Clock,
	Logger: Logger.Logger,
	GenerateId: () -> string,
	Settings: EvidenceSettings,
}

function EvidenceManager.new(options: EvidenceManagerOptions): EvidenceManager
	return setmetatable({
		_clock = options.Clock,
		_logger = options.Logger,
		_generateId = options.GenerateId,
		_settings = options.Settings,
		_stores = {},
	}, EvidenceManager)
end

local function snapshot(record: MutableRecord): EvidenceRecord
	return table.freeze(table.clone(record)) :: any
end

local function getStore(self: EvidenceManager, userId: number): Store
	local store = self._stores[userId]
	if store == nil then
		store = { records = {}, latest = {}, totalDetections = 0, merged = 0, evicted = 0, expired = 0 }
		self._stores[userId] = store
	end
	return store
end

local function removeAt(store: Store, index: number)
	local record = table.remove(store.records, index) :: MutableRecord
	local key = record.Detector .. "|" .. record.Kind
	if store.latest[key] == record then
		store.latest[key] = nil
	end
end

-- Records a detection event. Returns a frozen snapshot of the resulting record and
-- whether a new record was created (false = merged into an existing one).
function EvidenceManager.Record(self: EvidenceManager, event: DetectionEvent): (EvidenceRecord, boolean)
	local settings = self._settings
	local store = getStore(self, event.UserId)
	store.totalDetections += 1

	local key = event.Detector .. "|" .. event.Kind
	local existing = store.latest[key]
	if existing and event.Time - existing.LastSeen <= settings.DuplicateWindowSeconds then
		existing.Count += 1
		existing.LastSeen = event.Time
		existing.LastWallTime = event.WallTime
		existing.Severity = math.max(existing.Severity, event.Severity)
		existing.Confidence = math.max(existing.Confidence, event.Confidence)
		existing.Details = event.Details
		store.merged += 1
		return snapshot(existing), false
	end

	local record: MutableRecord = {
		Id = self._generateId(),
		UserId = event.UserId,
		SessionId = event.SessionId,
		Detector = event.Detector,
		Category = event.Category,
		Kind = event.Kind,
		Severity = event.Severity,
		Confidence = event.Confidence,
		Count = 1,
		FirstSeen = event.Time,
		LastSeen = event.Time,
		FirstWallTime = event.WallTime,
		LastWallTime = event.WallTime,
		FirstEventId = event.Id,
		Details = event.Details,
	}
	table.insert(store.records, record)
	store.latest[key] = record

	if #store.records > settings.MaxRecordsPerPlayer then
		local oldestIndex, oldestSeen = 1, math.huge
		for index, candidate in store.records do
			if candidate.LastSeen < oldestSeen then
				oldestIndex, oldestSeen = index, candidate.LastSeen
			end
		end
		removeAt(store, oldestIndex)
		store.evicted += 1
	end

	return snapshot(record), true
end

-- Frozen snapshots of a user's records, oldest first. Optional filter by Detector,
-- Category, or minimum LastSeen.
function EvidenceManager.Get(
	self: EvidenceManager,
	userId: number,
	filter: { Detector: string?, Category: string?, Since: number? }?
): { EvidenceRecord }
	local store = self._stores[userId]
	local result = {}
	if store == nil then
		return result
	end
	for _, record in store.records do
		if filter then
			if filter.Detector and record.Detector ~= filter.Detector then
				continue
			end
			if filter.Category and record.Category ~= filter.Category then
				continue
			end
			if filter.Since and record.LastSeen < filter.Since then
				continue
			end
		end
		table.insert(result, snapshot(record))
	end
	return result
end

function EvidenceManager.Summary(self: EvidenceManager, userId: number): EvidenceSummary
	local store = self._stores[userId]
	local byCategory: { [string]: number } = {}
	if store == nil then
		return { UserId = userId, Records = 0, TotalDetections = 0, Merged = 0, Evicted = 0, Expired = 0, ByCategory = byCategory }
	end
	for _, record in store.records do
		byCategory[record.Category] = (byCategory[record.Category] or 0) + record.Count
	end
	return {
		UserId = userId,
		Records = #store.records,
		TotalDetections = store.totalDetections,
		Merged = store.merged,
		Evicted = store.evicted,
		Expired = store.expired,
		ByCategory = byCategory,
	}
end

-- Removes records not seen within RetentionSeconds and drops empty stores.
-- Returns the number of records removed.
function EvidenceManager.Prune(self: EvidenceManager): number
	local now = self._clock.Now()
	local cutoff = now - self._settings.RetentionSeconds
	local removed = 0
	for userId, store in self._stores do
		local records = store.records
		for index = #records, 1, -1 do
			if records[index].LastSeen < cutoff then
				removeAt(store, index)
				store.expired += 1
				removed += 1
			end
		end
		if #records == 0 then
			self._stores[userId] = nil
		end
	end
	if removed > 0 then
		self._logger:Debug("Expired evidence pruned", { Removed = removed })
	end
	return removed
end

function EvidenceManager.Clear(self: EvidenceManager, userId: number?)
	if userId == nil then
		table.clear(self._stores)
	else
		self._stores[userId] = nil
	end
end

function EvidenceManager.GetStats(self: EvidenceManager): { Users: number, Records: number }
	local users, records = 0, 0
	for _, store in self._stores do
		users += 1
		records += #store.records
	end
	return { Users = users, Records = records }
end

return EvidenceManager
