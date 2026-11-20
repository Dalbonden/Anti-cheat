--!strict
--[[
	Enforcement audit log: every enforcement decision and staff action, bounded in memory
	and published on ACF.EnforcementAudit so the game can ship it to external storage.

	Entry: { Id, Time, WallTime, Type, UserId?, Level?, From?, To?, Band?, Risk?, Tags?,
	         By?, Reason?, AppealRef?, CaseId?, Shadow, Count?, Details? }

	Types: LevelChanged, Rejected, Corrected, Kicked, Banned, Unbanned, BanEnforced,
	BanExpired, CaseOpened, CaseUpdated, CaseApproved, CaseRejected, CaseExpired,
	OverrideSet, OverrideCleared, ShadowAction, PersistenceFailed.

	Repeated entries of one (UserId, Type, key) within RepeatIntervalSeconds are
	summarised: the first is written, later ones only increase a counter that is reported
	with the next entry (Count). That keeps a flood of rejections from flooding the log.
]]

local AuditLog = {}
AuditLog.__index = AuditLog

export type Entry = { [string]: any }

export type AuditLog = typeof(setmetatable(
	{} :: {
		_entries: { Entry },
		_max: number,
		_repeatInterval: number,
		_marks: { [string]: { At: number, Suppressed: number } },
		_now: () -> number,
		_wall: () -> number,
		_id: () -> string,
		_publish: (Entry) -> (),
		_total: number,
		_suppressed: number,
	},
	AuditLog
))

function AuditLog.new(options: {
	MaxEntries: number,
	RepeatIntervalSeconds: number,
	Now: () -> number,
	Wall: () -> number,
	GenerateId: () -> string,
	Publish: (Entry) -> (),
}): AuditLog
	return setmetatable({
		_entries = {},
		_max = options.MaxEntries,
		_repeatInterval = options.RepeatIntervalSeconds,
		_marks = {},
		_now = options.Now,
		_wall = options.Wall,
		_id = options.GenerateId,
		_publish = options.Publish,
		_total = 0,
		_suppressed = 0,
	}, AuditLog)
end

-- Appends an entry. With `repeatKey`, repeats inside the interval are summarised.
-- Returns the entry, or nil when it was summarised.
function AuditLog.Write(self: AuditLog, entryType: string, fields: { [string]: any }, repeatKey: string?): Entry?
	local now = self._now()
	local count: number? = nil
	if repeatKey then
		local markKey = `{entryType}:{tostring(fields.UserId)}:{repeatKey}`
		local mark = self._marks[markKey]
		if mark and now - mark.At < self._repeatInterval then
			mark.Suppressed += 1
			self._suppressed += 1
			return nil
		end
		if mark and mark.Suppressed > 0 then
			count = mark.Suppressed + 1
		end
		self._marks[markKey] = { At = now, Suppressed = 0 }
		-- Bound the marks table: forget marks older than the interval.
		local size = 0
		for _ in self._marks do
			size += 1
		end
		if size > self._max then
			for key, other in self._marks do
				if now - other.At >= self._repeatInterval then
					self._marks[key] = nil
				end
			end
		end
	end
	local entry: Entry = table.clone(fields)
	entry.Id = self._id()
	entry.Time = now
	entry.WallTime = self._wall()
	entry.Type = entryType
	entry.Shadow = fields.Shadow == true
	entry.Count = count
	local frozen = table.freeze(entry)
	table.insert(self._entries, frozen)
	while #self._entries > self._max do
		table.remove(self._entries, 1)
	end
	self._total += 1
	self._publish(frozen)
	return frozen
end

-- Entries oldest first, optionally filtered by { UserId?, Type?, Since? }.
function AuditLog.Get(self: AuditLog, filter: { UserId: number?, Type: string?, Since: number? }?): { Entry }
	local list = {}
	for _, entry in self._entries do
		if filter then
			if filter.UserId ~= nil and entry.UserId ~= filter.UserId then
				continue
			end
			if filter.Type ~= nil and entry.Type ~= filter.Type then
				continue
			end
			if filter.Since ~= nil and entry.Time < filter.Since then
				continue
			end
		end
		table.insert(list, entry)
	end
	return list
end

function AuditLog.GetStats(self: AuditLog): { [string]: number }
	return { Entries = #self._entries, Written = self._total, Summarised = self._suppressed }
end

return AuditLog
