--!strict
--[[
	EnforcementManager: graduated, hybrid enforcement (Phase 7). A core service, separate
	from detection (modules) and evidence/risk (Intelligence). It reads risk and decides
	what to do; modules only ask it questions through context.Enforcement.

	Inputs:
	  ACF.RiskChanged        band changes from the RiskEngine
	  ACF.DetectionReported  new evidence while a player is in the EnforcementReview
	                         band (so a kicked player who rejoins and cheats again escalates)
	  sessions               ban check on join; state kept per UserId

	Outputs (never while ShadowMode, except staff actions):
	  level 2  IsRestricted(user, tag) is true for tags = risk groups >= TagMinScore;
	           RemoteSecurity (spec.Restrict) and Combat consult it
	  level 3  ShouldCorrect(user) lets Movement rubber-band a Movement-tagged player
	  level 4  every tag is restricted for TemporaryRestrictionSeconds
	  5-7      kick / temporary ban / permanent ban: automatic only as EnforcementPolicy
	           allows, otherwise a case for staff approval
	  audit    every decision and staff action (AuditLog, ACF.EnforcementAudit)

	Records (bans, kick history, appeal references) persist through Environment.Store,
	read-modify-write, with retries. Without a Store they last for the server's life.
	Bans also use Environment.Enforcer:Ban (Roblox Players:BanAsync) when enabled.
]]

local EventBus = require(script.Parent.Parent.Core.EventBus)
local Topics = require(script.Parent.Parent.Core.Topics)
local Types = require(script.Parent.Parent.Types)
local AuditLog = require(script.Parent.AuditLog)
local BanRecords = require(script.Parent.BanRecords)
local EnforcementPolicy = require(script.Parent.EnforcementPolicy)

local AUTOMATIC = "ACF (automatic)"

local BAND_ORDER = { Normal = 1, Increased = 2, Restrict = 3, Investigation = 4, EnforcementReview = 5 }

export type Case = {
	CaseId: string,
	AppealRef: string,
	UserId: number,
	Type: string, -- "Action" (approve a level 5-7) | "Review" (investigate)
	ProposedLevel: number?,
	Status: string, -- "Open" | "Approved" | "Rejected" | "Expired" | "Shadow"
	Reason: string,
	Explanation: string,
	Risk: number,
	Band: string,
	CreatedAt: number,
	CreatedTime: number,
	DecidedBy: string?,
	DecidedAt: number?,
	Note: string?,
	ExecutedLevel: number?,
}

type Override = { Exempt: boolean, Level: number?, Until: number?, By: string, Reason: string? }

type RecordSlot = {
	Record: BanRecords.Record?,
	Loaded: boolean,
	Loading: boolean,
	LoadAttempts: number,
	Ops: { (BanRecords.Record) -> () },
	Dirty: boolean,
	SaveAttempts: number,
	Saving: boolean,
	OnLoaded: { (BanRecords.Record) -> () },
}

type User = {
	UserId: number,
	Level: number,
	Tags: { string },
	TagSet: { [string]: boolean },
	RestrictedUntil: number,
	Override: Override?,
	OpenCase: string?,
	AwaitingNewEvidence: boolean,
	-- Time of the last removal; only evidence after it clears AwaitingNewEvidence.
	RemovedAt: number,
	LastCorrection: number,
	InServer: boolean,
	Band: string,
	-- When the current restriction (level >= 2) began, and whether it has been sent for review.
	RestrictedSince: number?,
	RestrictionReviewed: boolean,
	LeftAt: number?,
}

export type Options = {
	Bus: EventBus.EventBus,
	Registry: any,
	Logger: any,
	Clock: Types.Clock,
	GenerateId: () -> string,
	Settings: { [string]: any },
	Risk: any?,
	Store: Types.KeyValueStore?,
	Enforcer: Types.Enforcer?,
}

local EnforcementManager = {}
EnforcementManager.__index = EnforcementManager

export type EnforcementManager = typeof(setmetatable(
	{} :: {
		_bus: EventBus.EventBus,
		_registry: any,
		_logger: any,
		_clock: Types.Clock,
		_id: () -> string,
		_settings: { [string]: any },
		_risk: any?,
		_store: Types.KeyValueStore?,
		_enforcer: Types.Enforcer?,
		_users: { [number]: User },
		_records: { [number]: RecordSlot },
		_cases: { [string]: Case },
		_caseOrder: { string },
		_audit: AuditLog.AuditLog,
		_running: boolean,
		_subscriptions: { EventBus.Subscription },
		_stats: { [string]: number },
	},
	EnforcementManager
))

local function staffName(by: any): string
	if type(by) == "string" and #by > 0 then
		return string.sub(by, 1, 100)
	elseif type(by) == "number" then
		return tostring(by)
	end
	error("ACF: staff actions need options.By (who is acting), for the audit log", 3)
end

local function round(value: number): number
	return math.floor(value * 10 + 0.5) / 10
end

function EnforcementManager.new(options: Options): EnforcementManager
	local self
	self = setmetatable({
		_bus = options.Bus,
		_registry = options.Registry,
		_logger = options.Logger,
		_clock = options.Clock,
		_id = options.GenerateId,
		_settings = options.Settings,
		_risk = options.Risk,
		_store = options.Store,
		_enforcer = options.Enforcer,
		_users = {},
		_records = {},
		_cases = {},
		_caseOrder = {},
		_audit = AuditLog.new({
			MaxEntries = options.Settings.Audit.MaxEntries,
			RepeatIntervalSeconds = options.Settings.Audit.RepeatIntervalSeconds,
			Now = options.Clock.Now,
			Wall = options.Clock.Wall,
			GenerateId = options.GenerateId,
			Publish = function(entry)
				options.Bus:Publish(Topics.EnforcementAudit, entry)
			end,
		}),
		_running = false,
		_subscriptions = {},
		_stats = {
			Kicks = 0,
			Bans = 0,
			Unbans = 0,
			BansEnforcedOnJoin = 0,
			Corrections = 0,
			Rejections = 0,
			CasesOpened = 0,
			RecordLoadFailures = 0,
			RecordSaveFailures = 0,
		},
	}, EnforcementManager)
	if options.Store == nil then
		options.Logger:Warn("No Store in the environment: bans and kick history last only for this server")
	end

	local function subscribe(topic: string, handler: (any) -> ())
		table.insert(self._subscriptions, options.Bus:Subscribe(topic, handler, "Enforcement"))
	end
	subscribe(Topics.RiskChanged, function(payload)
		if self._running then
			self:_reassess(payload.UserId, false)
		end
	end)
	subscribe(Topics.DetectionReported, function(payload)
		if not self._running then
			return
		end
		local user = self._users[payload.Event.UserId]
		if user and user.Band == "EnforcementReview" and user.InServer then
			-- The detection that caused a removal reaches this handler too (after the
			-- RiskEngine's); only evidence from after the removal counts as new.
			if payload.Event.Time > user.RemovedAt then
				user.AwaitingNewEvidence = false
			end
			self:_reassess(user.UserId, false)
		end
	end)
	subscribe(Topics.PlayerSessionStarted, function(payload)
		if self._running then
			self:_onJoin(payload.Session)
		end
	end)
	subscribe(Topics.PlayerSessionEnded, function(payload)
		local user = self._users[payload.Session.UserId]
		if user then
			user.InServer = false
			user.LeftAt = options.Clock.Now()
		end
	end)
	return self
end

-- Helpers -------------------------------------------------------------------------------

function EnforcementManager._user(self: EnforcementManager, userId: number): User
	local user = self._users[userId]
	if user == nil then
		user = {
			UserId = userId,
			Level = 0,
			Tags = {},
			TagSet = {},
			RestrictedUntil = -math.huge,
			Override = nil,
			OpenCase = nil,
			AwaitingNewEvidence = false,
			RemovedAt = -math.huge,
			LastCorrection = -math.huge,
			InServer = false,
			Band = "Normal",
			RestrictedSince = nil,
			RestrictionReviewed = false,
			LeftAt = nil,
		}
		self._users[userId] = user
	end
	return user
end

function EnforcementManager._shadow(self: EnforcementManager): boolean
	return self._settings.ShadowMode == true
end

function EnforcementManager._appealRef(self: EnforcementManager): string
	local raw = string.gsub(self._id(), "[^%w]", "")
	return "ACF-" .. string.upper(string.sub(raw, -8))
end

function EnforcementManager._player(self: EnforcementManager, userId: number): any?
	local session = self._registry:GetSession(userId)
	return if session then session.Player else nil
end

function EnforcementManager._overrideActive(self: EnforcementManager, user: User): Override?
	local override = user.Override
	if override == nil then
		return nil
	end
	if override.Until ~= nil and self._clock.Now() >= override.Until then
		user.Override = nil
		self._audit:Write("OverrideCleared", { UserId = user.UserId, By = AUTOMATIC, Reason = "expired" })
		return nil
	end
	return override
end

-- Records (persistence) -------------------------------------------------------------------

local function recordKey(userId: number): string
	return `Bans_{userId}`
end

function EnforcementManager._slot(self: EnforcementManager, userId: number): RecordSlot
	local slot = self._records[userId]
	if slot == nil then
		slot = {
			Record = nil,
			Loaded = false,
			Loading = false,
			LoadAttempts = 0,
			Ops = {},
			Dirty = false,
			SaveAttempts = 0,
			Saving = false,
			OnLoaded = {},
		}
		self._records[userId] = slot
		if self._store == nil then
			slot.Record = BanRecords.new(userId)
			slot.Loaded = true
		end
	end
	return slot
end

function EnforcementManager._applyOps(self: EnforcementManager, userId: number, slot: RecordSlot)
	local record = slot.Record :: BanRecords.Record
	local ops = slot.Ops
	slot.Ops = {}
	for _, op in ops do
		op(record)
		slot.Dirty = true
	end
	local callbacks = slot.OnLoaded
	slot.OnLoaded = {}
	for _, callback in callbacks do
		callback(record)
	end
end

function EnforcementManager._load(self: EnforcementManager, userId: number)
	local slot = self:_slot(userId)
	if slot.Loaded or slot.Loading or self._store == nil then
		return
	end
	slot.Loading = true
	slot.LoadAttempts += 1
	local store = self._store :: Types.KeyValueStore
	store:Load(self._settings.Bans.DataStoreName, recordKey(userId), function(ok: boolean, value: any, err: string?)
		slot.Loading = false
		if not ok then
			self._stats.RecordLoadFailures += 1
			if slot.LoadAttempts >= self._settings.Bans.MaxAttempts then
				self._logger:Error("Enforcement record could not be loaded; giving up", { UserId = userId, Error = err })
				self._audit:Write("PersistenceFailed", { UserId = userId, Reason = "load: " .. tostring(err) })
				-- Pending operations are applied to a fresh record rather than lost; the
				-- audit entry says the stored history could not be merged.
				slot.Record = BanRecords.new(userId)
				slot.Loaded = true
				self:_applyOps(userId, slot)
				self:_flush()
			else
				self._logger:Warn("Enforcement record load failed; will retry", { UserId = userId, Error = err })
			end
			return
		end
		slot.Record = BanRecords.fromStored(userId, value) or BanRecords.new(userId)
		slot.Loaded = true
		self:_applyOps(userId, slot)
		if slot.Dirty then
			self:_flush()
		end
	end)
end

-- Runs `op` on the user's record once it is loaded, then saves it.
function EnforcementManager._mutate(self: EnforcementManager, userId: number, op: (BanRecords.Record) -> ())
	local slot = self:_slot(userId)
	table.insert(slot.Ops, op)
	if slot.Loaded then
		self:_applyOps(userId, slot)
		self:_flush()
	else
		self:_load(userId)
	end
end

function EnforcementManager._withRecord(self: EnforcementManager, userId: number, callback: (BanRecords.Record) -> ())
	local slot = self:_slot(userId)
	if slot.Loaded then
		callback(slot.Record :: BanRecords.Record)
		return
	end
	table.insert(slot.OnLoaded, callback)
	self:_load(userId)
end

-- Saves dirty records and retries failed loads that still have work queued.
function EnforcementManager._flush(self: EnforcementManager)
	local store = self._store
	if store == nil then
		for _, slot in self._records do
			slot.Dirty = false
		end
		return
	end
	local bans = self._settings.Bans
	for userId, slot in self._records do
		if not slot.Loaded and not slot.Loading and (#slot.Ops > 0 or #slot.OnLoaded > 0) then
			self:_load(userId)
		elseif slot.Loaded and slot.Dirty and not slot.Saving then
			slot.Dirty = false
			slot.Saving = true
			slot.SaveAttempts += 1
			local record = slot.Record :: BanRecords.Record
			local snapshot = {
				Version = record.Version,
				UserId = record.UserId,
				Active = if record.Active then table.clone(record.Active) else nil,
				History = table.clone(record.History),
			}
			store:Save(bans.DataStoreName, recordKey(userId), snapshot, function(ok: boolean, err: string?)
				slot.Saving = false
				if ok then
					slot.SaveAttempts = 0
					return
				end
				self._stats.RecordSaveFailures += 1
				if slot.SaveAttempts < bans.MaxAttempts then
					self._logger:Warn("Enforcement record save failed; will retry", { UserId = userId, Error = err })
					slot.Dirty = true
				else
					self._logger:Error("Enforcement record save failed; giving up", { UserId = userId, Error = err })
					self._audit:Write("PersistenceFailed", { UserId = userId, Reason = "save: " .. tostring(err) })
					slot.SaveAttempts = 0
				end
			end)
		end
	end
end

-- Pending writes (for shutdown).
function EnforcementManager.Pending(self: EnforcementManager): number
	local count = 0
	for _, slot in self._records do
		if slot.Dirty or slot.Saving or slot.Loading or #slot.Ops > 0 then
			count += 1
		end
	end
	return count
end

-- Decisions ---------------------------------------------------------------------------------

function EnforcementManager._history(self: EnforcementManager, userId: number): (number, number)
	local slot = self._records[userId]
	if slot == nil or not slot.Loaded then
		return 0, 0
	end
	local record = slot.Record :: BanRecords.Record
	local since = self._clock.Wall() - self._settings.Bans.RepeatWindowDays * 86400
	return BanRecords.countSince(record, "Kick", since), BanRecords.countSince(record, "TemporaryBan", -math.huge)
end

function EnforcementManager._setLevel(self: EnforcementManager, user: User, level: number, tags: { string }, report: any, reason: string)
	local tagSet = {}
	for _, tag in tags do
		tagSet[tag] = true
	end
	local now = self._clock.Now()
	if level >= 4 and user.Level < 4 then
		user.RestrictedUntil = now + self._settings.TemporaryRestrictionSeconds
	end
	if level >= 2 and user.RestrictedSince == nil then
		user.RestrictedSince = now
	elseif level < 2 then
		user.RestrictedSince = nil
		user.RestrictionReviewed = false
	end
	local changed = level ~= user.Level or table.concat(tags, ",") ~= table.concat(user.Tags, ",")
	local from = user.Level
	user.Level = level
	user.Tags = tags
	user.TagSet = tagSet
	if changed then
		self._audit:Write("LevelChanged", {
			UserId = user.UserId,
			From = from,
			To = level,
			Level = EnforcementPolicy.levelName(level),
			Band = report.Band,
			Risk = round(report.Risk),
			Tags = table.clone(tags),
			Reason = reason,
			Shadow = self:_shadow(),
		})
	end
end

function EnforcementManager._openCase(self: EnforcementManager, user: User, caseType: string, proposed: number?, reason: string, report: any)
	local existing = if user.OpenCase then self._cases[user.OpenCase] else nil
	if existing and (existing.Status == "Open" or existing.Status == "Shadow") then
		if proposed and (existing.ProposedLevel or 0) < proposed then
			existing.Type = "Action"
			existing.ProposedLevel = proposed
			existing.Reason = reason
			existing.Explanation = report.Explanation
			existing.Risk = report.Risk
			existing.Band = report.Band
			self._audit:Write("CaseUpdated", { UserId = user.UserId, CaseId = existing.CaseId, Level = proposed, Reason = reason, Shadow = existing.Status == "Shadow" })
			self._bus:Publish(Topics.EnforcementCase, table.freeze(table.clone(existing)))
		end
		return
	end
	local caseId = self:_appealRef()
	local case: Case = {
		CaseId = caseId,
		AppealRef = caseId,
		UserId = user.UserId,
		Type = caseType,
		ProposedLevel = proposed,
		Status = if self:_shadow() then "Shadow" else "Open",
		Reason = reason,
		Explanation = report.Explanation,
		Risk = report.Risk,
		Band = report.Band,
		CreatedAt = self._clock.Wall(),
		CreatedTime = self._clock.Now(),
	}
	self._cases[caseId] = case
	table.insert(self._caseOrder, caseId)
	user.OpenCase = caseId
	self._stats.CasesOpened += 1
	self:_trimCases()
	self._audit:Write("CaseOpened", {
		UserId = user.UserId,
		CaseId = caseId,
		Level = proposed,
		Band = report.Band,
		Risk = round(report.Risk),
		Reason = reason,
		Shadow = case.Status == "Shadow",
	})
	self._bus:Publish(Topics.EnforcementCase, table.freeze(table.clone(case)))
end

function EnforcementManager._trimCases(self: EnforcementManager)
	local max = self._settings.Cases.MaxOpen
	if #self._caseOrder <= max then
		return
	end
	-- Drop the oldest closed cases first, then the oldest open ones.
	for pass = 1, 2 do
		local index = 1
		while #self._caseOrder > max and index <= #self._caseOrder do
			local case = self._cases[self._caseOrder[index]]
			local closed = case.Status ~= "Open" and case.Status ~= "Shadow"
			if pass == 2 or closed then
				self._cases[case.CaseId] = nil
				table.remove(self._caseOrder, index)
			else
				index += 1
			end
		end
	end
end

-- Re-evaluates one user from their current risk.
function EnforcementManager._reassess(self: EnforcementManager, userId: number, joining: boolean)
	local risk = self._risk
	if risk == nil then
		return
	end
	-- A departed player who has already been forgotten has nothing to restrict; tracking
	-- them again on every decaying band change would grow memory without bound.
	if self._users[userId] == nil and not joining and self._registry:GetSession(userId) == nil then
		return
	end
	local user = self:_user(userId)
	local report = risk:Get(userId)
	local previousBand = user.Band
	user.Band = report.Band
	local rising = BAND_ORDER[report.Band] > BAND_ORDER[previousBand]
	local present = user.InServer or joining
	local override = self:_overrideActive(user)
	if override and override.Exempt then
		self:_setLevel(user, 0, {}, report, "override: exempt")
		return
	end
	local kicks, tempBans = self:_history(userId)
	local decision = EnforcementPolicy.decide({
		Band = report.Band,
		Risk = report.Risk,
		Confidence = report.Confidence,
		Groups = report.Groups,
		RecentKicks = kicks,
		TemporaryBans = tempBans,
	}, self._settings)

	local level = math.min(decision.Level, 4)
	if override and override.Level then
		level = override.Level
	end
	self:_setLevel(user, level, decision.Tags, report, if override then "override: level" else decision.Reason)

	-- Review cases only when the band RISES into Investigation for a present player:
	-- decaying through the band, or having left, is no reason to call staff.
	if report.Band == "Investigation" and decision.Proposed == nil and rising and present then
		self:_openCase(user, "Review", nil, decision.Reason, report)
	end
	if not user.InServer and not joining then
		return
	end
	-- After a removal, wait for new evidence before removing again.
	if user.AwaitingNewEvidence then
		return
	end
	if decision.Level >= 5 then
		if self:_shadow() then
			self._audit:Write("ShadowAction", {
				UserId = userId,
				Level = EnforcementPolicy.levelName(decision.Level),
				Band = report.Band,
				Risk = round(report.Risk),
				Reason = decision.Reason,
				Shadow = true,
			}, EnforcementPolicy.levelName(decision.Level))
			return
		end
		self:_execute(userId, decision.Level, AUTOMATIC, decision.Reason, nil, nil)
	elseif decision.Proposed then
		self:_openCase(user, "Action", decision.Proposed, decision.Reason, report)
	end
end

-- Executes a removal (5 kick, 6 temporary ban, 7 permanent ban).
function EnforcementManager._execute(
	self: EnforcementManager,
	userId: number,
	level: number,
	by: string,
	reason: string,
	approvedBy: string?,
	hours: number?
): string
	local settings = self._settings
	local appeal = self:_appealRef()
	local user = self:_user(userId)
	user.AwaitingNewEvidence = true
	user.RemovedAt = self._clock.Now()
	local wall = self._clock.Wall()
	local player = self:_player(userId)
	local enforcer = self._enforcer

	if level == 5 then
		self._stats.Kicks += 1
		self:_mutate(userId, function(record)
			BanRecords.addHistory(record, { Type = "Kick", At = wall, AppealRef = appeal, Reason = reason, By = by }, settings.Bans.MaxHistory)
		end)
		self._audit:Write("Kicked", { UserId = userId, AppealRef = appeal, By = by, ApprovedBy = approvedBy, Reason = reason, Offline = player == nil })
		if player and enforcer then
			enforcer:Kick(player, BanRecords.format(settings.Messages.Kick, appeal, nil))
		end
		return appeal
	end

	-- Bans: level 6 temporary, level 7 permanent. The ban takes effect immediately; the
	-- record write follows when the stored record has loaded.
	self._stats.Bans += 1
	local expiresAt: number? = nil
	if level == 6 then
		local slot = self._records[userId]
		local known = if slot and slot.Loaded then slot.Record else nil
		local duration = hours
			or BanRecords.tempBanHours(
				known or BanRecords.new(userId),
				settings.Bans.TempBanHours,
				settings.Bans.EscalationFactor,
				settings.Bans.MaxTempBanHours
			)
		expiresAt = wall + duration * 3600
	end
	local message = BanRecords.format(
		if level == 6 then settings.Messages.TempBan else settings.Messages.PermanentBan,
		appeal,
		expiresAt
	)
	self:_mutate(userId, function(record)
		record.Active = {
			Level = level,
			AppealRef = appeal,
			Reason = reason,
			By = by,
			IssuedAt = wall,
			ExpiresAt = expiresAt,
			ApprovedBy = approvedBy,
		}
		BanRecords.addHistory(record, {
			Type = if level == 6 then "TemporaryBan" else "PermanentBan",
			At = wall,
			AppealRef = appeal,
			Reason = reason,
			By = by,
			ExpiresAt = expiresAt,
		}, settings.Bans.MaxHistory)
	end)
	self._audit:Write("Banned", {
		UserId = userId,
		AppealRef = appeal,
		Level = EnforcementPolicy.levelName(level),
		By = by,
		ApprovedBy = approvedBy,
		Reason = reason,
		ExpiresAt = expiresAt,
		Offline = player == nil,
	})
	local banApi = if enforcer then enforcer.Ban else nil
	if banApi and settings.Bans.UseRobloxBanApi then
		local seconds = if expiresAt then math.max(1, math.floor(expiresAt - wall)) else nil
		banApi(enforcer, userId, seconds, message, `{appeal}: {reason}`, function(ok: boolean, err: string?)
			if not ok then
				self._logger:Error("Roblox ban API call failed; the ACF record still enforces the ban on join", {
					UserId = userId,
					Error = err,
				})
			end
		end)
	end
	if player and enforcer then
		enforcer:Kick(player, message)
	end
	return appeal
end

-- Join: enforce an active ban, expire an old one, and resume restrictions.
function EnforcementManager._onJoin(self: EnforcementManager, session: any)
	local userId = session.UserId
	local user = self:_user(userId)
	user.InServer = true
	user.LeftAt = nil
	if self._settings.Bans.CheckOnJoin then
		self:_withRecord(userId, function(record)
			local wall = self._clock.Wall()
			if BanRecords.expire(record, wall, self._settings.Bans.MaxHistory) then
				self:_slot(userId).Dirty = true
				self._audit:Write("BanExpired", { UserId = userId })
				self:_flush()
			end
			local ban = BanRecords.activeBan(record, wall)
			local current = self._registry:GetSession(userId)
			if ban and current and current.SessionId == session.SessionId and self._enforcer then
				self._stats.BansEnforcedOnJoin += 1
				self._audit:Write("BanEnforced", { UserId = userId, AppealRef = ban.AppealRef, ExpiresAt = ban.ExpiresAt })
				local template = if ban.Level == 6 then self._settings.Messages.TempBan else self._settings.Messages.PermanentBan
				local enforcer = self._enforcer :: Types.Enforcer
				enforcer:Kick(current.Player, BanRecords.format(template, ban.AppealRef, ban.ExpiresAt))
			end
		end)
	end
	self:_reassess(userId, true)
end

-- Whether nothing about a departed user still needs memory.
function EnforcementManager._forgettable(self: EnforcementManager, user: User, now: number): boolean
	if user.InServer or user.LeftAt == nil or now - user.LeftAt < self._settings.ForgetAfterSeconds then
		return false
	end
	if user.Override ~= nil then
		return false
	end
	-- Open cases do not pin a user: they refer to the UserId, and approving one works
	-- without in-memory state.
	local slot = self._records[user.UserId]
	return slot == nil or not (slot.Dirty or slot.Saving or slot.Loading or #slot.Ops > 0 or #slot.OnLoaded > 0)
end

-- Periodic: expire temporary restrictions, overrides and old cases; send long
-- restrictions for review; forget departed users.
function EnforcementManager.Tick(self: EnforcementManager)
	local now = self._clock.Now()
	local reviewAfter = self._settings.Cases.ReviewAfterRestrictedSeconds
	for userId, user in self._users do
		self:_overrideActive(user)
		if user.Level >= 4 and user.RestrictedUntil <= now then
			self:_reassess(userId, false)
		end
		local since = user.RestrictedSince
		if
			user.InServer
			and since ~= nil
			and not user.RestrictionReviewed
			and now - since >= reviewAfter
			and self._risk ~= nil
		then
			user.RestrictionReviewed = true
			local report = (self._risk :: any):Get(userId)
			self:_openCase(user, "Review", nil, `restricted for {math.floor((now - since) / 60)} min (level {user.Level})`, report)
		end
		if self:_forgettable(user, now) then
			self._users[userId] = nil
			if self._store ~= nil then
				self._records[userId] = nil
			end
		end
	end
	-- Record slots of users no longer tracked (offline bans, lookups) once idle. Without a
	-- Store the slot is the only copy of a ban, so it is kept.
	if self._store ~= nil then
		for userId, slot in self._records do
			if self._users[userId] == nil and not (slot.Dirty or slot.Saving or slot.Loading or #slot.Ops > 0 or #slot.OnLoaded > 0) then
				self._records[userId] = nil
			end
		end
	end
	local expiry = self._settings.Cases.ExpiryHours * 3600
	local wall = self._clock.Wall()
	for _, caseId in self._caseOrder do
		local case = self._cases[caseId]
		if (case.Status == "Open" or case.Status == "Shadow") and wall - case.CreatedAt >= expiry then
			case.Status = "Expired"
			self._audit:Write("CaseExpired", { UserId = case.UserId, CaseId = caseId })
			local user = self._users[case.UserId]
			if user and user.OpenCase == caseId then
				user.OpenCase = nil
			end
		end
	end
	self:_flush()
end

-- Questions modules ask (context.Enforcement) -----------------------------------------------

-- Whether operations tagged `tag` (a risk group name, or true for "any") are restricted.
function EnforcementManager.IsRestricted(self: EnforcementManager, userId: number, tag: string | boolean, operation: string?): boolean
	local user = self._users[userId]
	if user == nil or user.Level < 2 then
		return false
	end
	local override = self:_overrideActive(user)
	if override and override.Exempt then
		return false
	end
	local restricted = false
	if user.Level >= 4 and user.RestrictedUntil > self._clock.Now() then
		restricted = true
	elseif tag == true then
		restricted = #user.Tags > 0
	elseif type(tag) == "string" then
		restricted = user.TagSet[tag] == true
	end
	if not restricted then
		return false
	end
	local shadow = self:_shadow()
	self._audit:Write("Rejected", {
		UserId = userId,
		Tags = table.clone(user.Tags),
		Reason = operation,
		Level = EnforcementPolicy.levelName(user.Level),
		Shadow = shadow,
	}, tostring(operation))
	if shadow then
		return false
	end
	self._stats.Rejections += 1
	return true
end

-- Whether Movement may correct this player now (consumes the cooldown when true).
function EnforcementManager.ShouldCorrect(self: EnforcementManager, userId: number): boolean
	local correction = self._settings.Correction
	local user = self._users[userId]
	if not correction.Enabled or user == nil or user.Level < 3 or not user.TagSet.Movement then
		return false
	end
	local override = self:_overrideActive(user)
	if override and override.Exempt then
		return false
	end
	local now = self._clock.Now()
	if now - user.LastCorrection < correction.CooldownSeconds then
		return false
	end
	if self:_shadow() then
		self._audit:Write("Corrected", { UserId = userId, Shadow = true }, "movement")
		return false
	end
	user.LastCorrection = now
	return true
end

function EnforcementManager.NoteCorrected(self: EnforcementManager, userId: number, details: { [string]: any })
	self._stats.Corrections += 1
	self._audit:Write("Corrected", { UserId = userId, Details = details }, "movement")
end

-- Staff and API ------------------------------------------------------------------------------

function EnforcementManager.Approve(self: EnforcementManager, caseId: string, options: { By: any, Level: number?, Note: string?, Hours: number? })
	local by = staffName(options.By)
	local case = self._cases[caseId]
	if case == nil then
		error(`ACF: unknown case '{tostring(caseId)}'`, 2)
	end
	if case.Status ~= "Open" then
		error(`ACF: case {caseId} is {case.Status}, not Open`, 2)
	end
	local level = options.Level or case.ProposedLevel
	if level == nil or level < 5 or level > 7 then
		error("ACF: Approve needs a removal Level of 5 (kick), 6 (temporary ban) or 7 (permanent ban)", 2)
	end
	case.Status = "Approved"
	case.DecidedBy = by
	case.DecidedAt = self._clock.Wall()
	case.Note = options.Note
	case.ExecutedLevel = level
	local user = self:_user(case.UserId)
	if user.OpenCase == caseId then
		user.OpenCase = nil
	end
	self._audit:Write("CaseApproved", { UserId = case.UserId, CaseId = caseId, Level = EnforcementPolicy.levelName(level), By = by, Reason = options.Note })
	self:_execute(case.UserId, level, by, `case {caseId}: {case.Reason}`, by, options.Hours)
	self._bus:Publish(Topics.EnforcementCase, table.freeze(table.clone(case)))
end

function EnforcementManager.Reject(self: EnforcementManager, caseId: string, options: { By: any, Note: string? })
	local by = staffName(options.By)
	local case = self._cases[caseId]
	if case == nil then
		error(`ACF: unknown case '{tostring(caseId)}'`, 2)
	end
	if case.Status ~= "Open" and case.Status ~= "Shadow" then
		error(`ACF: case {caseId} is {case.Status}`, 2)
	end
	case.Status = "Rejected"
	case.DecidedBy = by
	case.DecidedAt = self._clock.Wall()
	case.Note = options.Note
	local user = self._users[case.UserId]
	if user and user.OpenCase == caseId then
		user.OpenCase = nil
	end
	self._audit:Write("CaseRejected", { UserId = case.UserId, CaseId = caseId, By = by, Reason = options.Note })
	self._bus:Publish(Topics.EnforcementCase, table.freeze(table.clone(case)))
end

function EnforcementManager.Kick(self: EnforcementManager, userId: number, options: { By: any, Reason: string? }): string
	local by = staffName(options.By)
	return self:_execute(userId, 5, by, options.Reason or "staff kick", by, nil)
end

-- options.Hours = nil bans permanently.
function EnforcementManager.Ban(self: EnforcementManager, userId: number, options: { By: any, Reason: string?, Hours: number? }): string
	local by = staffName(options.By)
	local hours = options.Hours
	if hours ~= nil and (type(hours) ~= "number" or hours <= 0 or hours ~= hours) then
		error("ACF: Ban Hours must be a positive number (omit it for a permanent ban)", 2)
	end
	return self:_execute(userId, if hours then 6 else 7, by, options.Reason or "staff ban", by, hours)
end

function EnforcementManager.Unban(self: EnforcementManager, userId: number, options: { By: any, Reason: string? })
	local by = staffName(options.By)
	self._stats.Unbans += 1
	local wall = self._clock.Wall()
	local bans = self._settings.Bans
	self:_mutate(userId, function(record)
		local previous = record.Active
		record.Active = nil
		BanRecords.addHistory(record, {
			Type = "Unban",
			At = wall,
			AppealRef = if previous then previous.AppealRef else nil,
			Reason = options.Reason,
			By = by,
		}, bans.MaxHistory)
	end)
	local enforcer = self._enforcer
	local unbanApi = if enforcer then enforcer.Unban else nil
	if unbanApi and bans.UseRobloxBanApi then
		unbanApi(enforcer, userId, function(ok: boolean, err: string?)
			if not ok then
				self._logger:Error("Roblox unban API call failed", { UserId = userId, Error = err })
			end
		end)
	end
	self._audit:Write("Unbanned", { UserId = userId, By = by, Reason = options.Reason })
end

-- options: { Exempt = true } or { Level = 0-4 }, plus Seconds?, By, Reason?.
function EnforcementManager.SetOverride(self: EnforcementManager, userId: number, options: { [string]: any })
	local by = staffName(options.By)
	local level = options.Level
	if options.Exempt ~= true and (type(level) ~= "number" or level < 0 or level > 4 or level ~= math.floor(level)) then
		error("ACF: SetOverride needs Exempt = true or a Level from 0 to 4 (use Kick/Ban for removals)", 2)
	end
	local seconds = options.Seconds
	if seconds ~= nil and (type(seconds) ~= "number" or seconds <= 0) then
		error("ACF: SetOverride Seconds must be a positive number", 2)
	end
	local user = self:_user(userId)
	user.Override = {
		Exempt = options.Exempt == true,
		Level = if options.Exempt == true then nil else level,
		Until = if seconds then self._clock.Now() + seconds else nil,
		By = by,
		Reason = options.Reason,
	}
	self._audit:Write("OverrideSet", {
		UserId = userId,
		By = by,
		Reason = options.Reason,
		Level = if options.Exempt == true then "Exempt" else EnforcementPolicy.levelName(level),
		Seconds = seconds,
	})
	self:_reassess(userId, false)
	if self._risk == nil then
		user.Level = if options.Exempt == true then 0 else level
	end
end

function EnforcementManager.ClearOverride(self: EnforcementManager, userId: number, options: { By: any, Reason: string? })
	local by = staffName(options.By)
	local user = self:_user(userId)
	user.Override = nil
	self._audit:Write("OverrideCleared", { UserId = userId, By = by, Reason = options.Reason })
	self:_reassess(userId, false)
end

function EnforcementManager.Get(self: EnforcementManager, userId: number): { [string]: any }
	local user = self._users[userId]
	local slot = self._records[userId]
	local record = if slot and slot.Loaded then slot.Record else nil
	local now = self._clock.Now()
	local override = if user then self:_overrideActive(user) else nil
	local level = if user then user.Level else 0
	return {
		UserId = userId,
		Level = level,
		LevelName = EnforcementPolicy.levelName(level),
		Tags = if user then table.clone(user.Tags) else {},
		RestrictedFor = if user and user.Level >= 4 then math.max(0, user.RestrictedUntil - now) else 0,
		Shadow = self:_shadow(),
		Override = if override then table.clone(override) else nil,
		OpenCase = if user then user.OpenCase else nil,
		RecordLoaded = record ~= nil,
		Ban = if record and BanRecords.activeBan(record, self._clock.Wall()) then table.clone(record.Active :: any) else nil,
		History = if record then table.clone(record.History) else nil,
	}
end

function EnforcementManager.GetCases(self: EnforcementManager, filter: { Status: string?, UserId: number? }?): { Case }
	local list = {}
	for _, caseId in self._caseOrder do
		local case = self._cases[caseId]
		if filter then
			if filter.Status ~= nil and case.Status ~= filter.Status then
				continue
			end
			if filter.UserId ~= nil and case.UserId ~= filter.UserId then
				continue
			end
		end
		table.insert(list, table.freeze(table.clone(case)))
	end
	return list
end

function EnforcementManager.GetAudit(self: EnforcementManager, filter: any?): { AuditLog.Entry }
	return self._audit:Get(filter)
end

-- Loads (if needed) and returns a user's record through `callback(record)`.
function EnforcementManager.LoadRecord(self: EnforcementManager, userId: number, callback: (any) -> ())
	self:_withRecord(userId, function(record)
		callback({
			UserId = record.UserId,
			Ban = BanRecords.activeBan(record, self._clock.Wall()),
			History = table.clone(record.History),
		})
	end)
end

function EnforcementManager.GetStats(self: EnforcementManager): { [string]: any }
	local stats = table.clone(self._stats) :: { [string]: any }
	local open, levels = 0, {}
	for _, case in self._cases do
		if case.Status == "Open" then
			open += 1
		end
	end
	for _, user in self._users do
		if user.Level > 0 then
			local name = EnforcementPolicy.levelName(user.Level)
			levels[name] = (levels[name] or 0) + 1
		end
	end
	stats.OpenCases = open
	stats.Levels = levels
	stats.Shadow = self:_shadow()
	stats.Mode = self._settings.Mode
	stats.PendingWrites = self:Pending()
	local users, records = 0, 0
	for _ in self._users do
		users += 1
	end
	for _ in self._records do
		records += 1
	end
	stats.Users = users
	stats.Records = records
	stats.Audit = self._audit:GetStats()
	return stats
end

-- Lifecycle -----------------------------------------------------------------------------------

function EnforcementManager.Start(self: EnforcementManager, scheduler: any, cleanup: any, onShutdown: any?)
	self._running = true
	cleanup:Add(scheduler:Every("ACF.Enforcement", self._settings.Bans.FlushIntervalSeconds, function()
		self:Tick()
	end))
	if onShutdown and not (self :: any)._shutdownRegistered then
		(self :: any)._shutdownRegistered = true
		onShutdown(function()
			self:_flush()
		end, function(): number
			return self:Pending()
		end)
	end
end

function EnforcementManager.Stop(self: EnforcementManager)
	self:_flush()
	self._running = false
end

function EnforcementManager.Destroy(self: EnforcementManager)
	self._running = false
	for _, subscription in self._subscriptions do
		subscription:Disconnect()
	end
	table.clear(self._subscriptions)
end

return EnforcementManager
