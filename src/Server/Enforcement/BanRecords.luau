--!strict
--[[
	Pure helpers for persisted enforcement records (one per UserId).

	Record (DataStore "ACF_Bans_v1", key "Bans_<UserId>"):
	  {
	    Version = 1,
	    UserId = number,
	    Active = nil | {                       -- the ban currently in force
	      Level = 6 | 7, AppealRef = "ACF-...", Reason = string, By = string,
	      IssuedAt = unix, ExpiresAt = unix | nil (permanent), ApprovedBy = string?,
	    },
	    History = { {                            -- newest last, bounded
	      Type = "Kick" | "TemporaryBan" | "PermanentBan" | "Unban" | "Expired",
	      At = unix, AppealRef = string?, Reason = string?, By = string?,
	      ExpiresAt = unix?,
	    } },
	  }
]]

local BanRecords = {}

BanRecords.VERSION = 1

export type Ban = {
	Level: number,
	AppealRef: string,
	Reason: string,
	By: string,
	IssuedAt: number,
	ExpiresAt: number?,
	ApprovedBy: string?,
}

export type Entry = {
	Type: string,
	At: number,
	AppealRef: string?,
	Reason: string?,
	By: string?,
	ExpiresAt: number?,
}

export type Record = {
	Version: number,
	UserId: number,
	Active: Ban?,
	History: { Entry },
}

function BanRecords.new(userId: number): Record
	return { Version = BanRecords.VERSION, UserId = userId, Active = nil, History = {} }
end

local function str(value: any, max: number): string?
	if type(value) ~= "string" then
		return nil
	end
	return string.sub(value, 1, max)
end

local function num(value: any): number?
	if type(value) == "number" and value == value and value > -math.huge and value < math.huge then
		return value
	end
	return nil
end

-- Validates a stored value. Returns a clean record, or nil when it is not one.
function BanRecords.fromStored(userId: number, value: any): Record?
	if type(value) ~= "table" or value.Version ~= BanRecords.VERSION then
		return nil
	end
	local record = BanRecords.new(userId)
	local active = value.Active
	if type(active) == "table" and (active.Level == 6 or active.Level == 7) and num(active.IssuedAt) then
		record.Active = {
			Level = active.Level,
			AppealRef = str(active.AppealRef, 32) or "unknown",
			Reason = str(active.Reason, 400) or "",
			By = str(active.By, 100) or "unknown",
			IssuedAt = active.IssuedAt,
			ExpiresAt = num(active.ExpiresAt),
			ApprovedBy = str(active.ApprovedBy, 100),
		}
	end
	if type(value.History) == "table" then
		for _, entry in value.History do
			if type(entry) == "table" and type(entry.Type) == "string" and num(entry.At) then
				table.insert(record.History, {
					Type = string.sub(entry.Type, 1, 32),
					At = entry.At,
					AppealRef = str(entry.AppealRef, 32),
					Reason = str(entry.Reason, 400),
					By = str(entry.By, 100),
					ExpiresAt = num(entry.ExpiresAt),
				})
			end
		end
	end
	return record
end

function BanRecords.addHistory(record: Record, entry: Entry, max: number)
	table.insert(record.History, entry)
	while #record.History > max do
		table.remove(record.History, 1)
	end
end

-- The ban in force at wall time `now`, or nil.
function BanRecords.activeBan(record: Record, now: number): Ban?
	local ban = record.Active
	if ban == nil then
		return nil
	end
	if ban.ExpiresAt ~= nil and now >= ban.ExpiresAt then
		return nil
	end
	return ban
end

-- Moves an expired ban into history. Returns true when the record changed.
function BanRecords.expire(record: Record, now: number, max: number): boolean
	local ban = record.Active
	if ban == nil or ban.ExpiresAt == nil or now < ban.ExpiresAt then
		return false
	end
	record.Active = nil
	BanRecords.addHistory(record, {
		Type = "Expired",
		At = ban.ExpiresAt :: number,
		AppealRef = ban.AppealRef,
		Reason = nil,
		By = nil,
		ExpiresAt = nil,
	}, max)
	return true
end

function BanRecords.countSince(record: Record, entryType: string, since: number): number
	local count = 0
	for _, entry in record.History do
		if entry.Type == entryType and entry.At >= since then
			count += 1
		end
	end
	return count
end

-- Temporary-ban length in hours: base x factor^(previous temporary bans), capped.
function BanRecords.tempBanHours(record: Record, base: number, factor: number, max: number): number
	local previous = BanRecords.countSince(record, "TemporaryBan", -math.huge)
	return math.min(max, base * factor ^ previous)
end

-- Fills {appeal} and {until} in a message template.
function BanRecords.format(template: string, appealRef: string, expiresAt: number?): string
	local untilText = if expiresAt then os.date("!%Y-%m-%d %H:%M UTC", math.floor(expiresAt)) else "further notice"
	local text = string.gsub(template, "{appeal}", appealRef)
	text = string.gsub(text, "{until}", untilText :: string)
	return text
end

return BanRecords
