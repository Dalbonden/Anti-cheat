--!strict
--[[
	RiskEngine: centralised risk assessment (Phase 6). A core service, not a module:
	it consumes every accepted detection (ACF.DetectionReported) from every module and
	keeps one risk score per user. The mathematics lives in RiskModel.

	Responsibilities:
	  - Confidence-weighted, exponentially decaying evidence per (Detector, Kind) key.
	  - Duplicate suppression: repeats of one key within RepeatSuppressSeconds are not
	    added; repeats beyond that saturate (RiskModel.add).
	  - Correlation: keys are grouped (Risk.Groups) so related detections count once.
	  - Bands: Normal / Increased / Restrict / Investigation / EnforcementReview;
	    ACF.RiskChanged is published whenever a user's band changes (up or down).
	  - Session risk keyed by UserId within this server, so leaving and rejoining does
	    not reset it; it decays like any other evidence.
	  - Persistent risk (opt-in, Risk.Persistence): a session that ends at or above
	    MinRiskToSave is saved, in batches, with retries. On the next join, the saved risk
	    (weighted, decayed by wall-clock time, capped) seeds the session as "History".
	    Storage failures never raise risk: a failed load means no history.
	  - Evidence history and explanations for every user.

	This service never punishes anyone. Phase 7 enforcement consumes RiskChanged.
]]

local EventBus = require(script.Parent.Parent.Core.EventBus)
local Topics = require(script.Parent.Parent.Core.Topics)
local RiskModel = require(script.Parent.RiskModel)
local Types = require(script.Parent.Parent.Types)

local RECORD_VERSION = 1
local PRUNE_SCORE = 0.05

export type HistoryEntry = {
	Time: number,
	WallTime: number,
	Type: string, -- "Detection" | "Band" | "History" | "Reset"
	Detector: string?,
	Kind: string?,
	Group: string?,
	Contribution: number?,
	Risk: number,
	Band: string,
	Note: string?,
}

type User = {
	UserId: number,
	Keys: { [string]: RiskModel.Key },
	KeyCount: number,
	Persistent: number,
	Risk: number,
	Peak: number,
	Confidence: number,
	Band: string,
	Groups: { RiskModel.GroupSummary },
	History: { HistoryEntry },
	InServer: boolean,
	SessionId: string?,
	Loaded: boolean,
	Stored: { [string]: any }?,
}

type QueueItem = { UserId: number, Record: { [string]: any }, Attempts: number }

export type Options = {
	Bus: EventBus.EventBus,
	Registry: any,
	Logger: any,
	Clock: Types.Clock,
	Settings: { [string]: any },
	Store: Types.KeyValueStore?,
	OnShutdown: ((flush: () -> (), pending: () -> number) -> ())?,
}

local RiskEngine = {}
RiskEngine.__index = RiskEngine

export type RiskEngine = typeof(setmetatable(
	{} :: {
		_bus: EventBus.EventBus,
		_registry: any,
		_logger: any,
		_clock: Types.Clock,
		_settings: { [string]: any },
		_store: Types.KeyValueStore?,
		_persist: boolean,
		_users: { [number]: User },
		_queue: { QueueItem },
		_inFlight: number,
		_running: boolean,
		_subscriptions: { EventBus.Subscription },
		_shutdownRegistered: boolean,
		_onShutdown: ((flush: () -> (), pending: () -> number) -> ())?,
		_stats: { [string]: number },
	},
	RiskEngine
))

local function validateBands(bands: { [string]: number })
	local order = { "Increased", "Restrict", "Investigation", "EnforcementReview" }
	for index = 2, #order do
		if bands[order[index]] <= bands[order[index - 1]] then
			error(`ACF configuration is invalid:\n  - Risk.Bands.{order[index]} must be greater than Risk.Bands.{order[index - 1]}`, 0)
		end
	end
end

function RiskEngine.new(options: Options): RiskEngine
	local settings = options.Settings
	validateBands(settings.Bands)
	local persist = settings.Persistence.Enabled == true
	if persist and options.Store == nil then
		options.Logger:Warn("Risk.Persistence is enabled but the environment has no Store; persistence is off")
		persist = false
	end
	local self = setmetatable({
		_bus = options.Bus,
		_registry = options.Registry,
		_logger = options.Logger,
		_clock = options.Clock,
		_settings = settings,
		_store = options.Store,
		_persist = persist,
		_users = {},
		_queue = {},
		_inFlight = 0,
		_running = false,
		_subscriptions = {},
		_shutdownRegistered = false,
		_onShutdown = options.OnShutdown,
		_stats = {
			Detections = 0,
			Suppressed = 0,
			BandChanges = 0,
			Loaded = 0,
			LoadFailed = 0,
			Saved = 0,
			SaveRetries = 0,
			SaveFailed = 0,
			Evicted = 0,
		},
	}, RiskEngine)

	-- Subscribed for the framework's whole life; gated by _running.
	table.insert(self._subscriptions, options.Bus:Subscribe(Topics.DetectionReported, function(payload)
		self:_onDetection(payload)
	end, "Intelligence.Risk"))
	table.insert(self._subscriptions, options.Bus:Subscribe(Topics.PlayerSessionStarted, function(payload)
		self:_onSessionStarted(payload.Session)
	end, "Intelligence.Risk"))
	table.insert(self._subscriptions, options.Bus:Subscribe(Topics.PlayerSessionEnded, function(payload)
		self:_onSessionEnded(payload.Session)
	end, "Intelligence.Risk"))
	return self
end

-- Users and evaluation ---------------------------------------------------------------

local function newUser(userId: number): User
	return {
		UserId = userId,
		Keys = {},
		KeyCount = 0,
		Persistent = 0,
		Risk = 0,
		Peak = 0,
		Confidence = 0,
		Band = "Normal",
		Groups = {},
		History = {},
		InServer = false,
		SessionId = nil,
		Loaded = false,
		Stored = nil,
	}
end

function RiskEngine._user(self: RiskEngine, userId: number): User
	local user = self._users[userId]
	if user == nil then
		user = newUser(userId)
		self._users[userId] = user
	end
	return user
end

function RiskEngine._record(self: RiskEngine, user: User, entry: HistoryEntry)
	local history = user.History
	table.insert(history, entry)
	while #history > self._settings.MaxHistory do
		table.remove(history, 1)
	end
end

-- Recomputes a user's risk at `now`; publishes RiskChanged on a band change.
function RiskEngine._evaluate(self: RiskEngine, user: User, now: number)
	local settings = self._settings
	local keys: { RiskModel.Key } = {}
	for _, key in user.Keys do
		RiskModel.age(key, now, settings.HalfLifeSeconds)
		table.insert(keys, key)
	end
	local groups = RiskModel.summarize(keys, settings.SecondaryWeight)
	local risk, confidence = RiskModel.combine(groups, user.Persistent)
	local previous, previousBand = user.Risk, user.Band
	local band = RiskModel.band(risk, settings.Bands)
	user.Risk = risk
	user.Confidence = confidence
	user.Groups = groups
	user.Peak = math.max(user.Peak, risk)
	user.Band = band
	if band ~= previousBand then
		self._stats.BandChanges += 1
		local explanation = RiskModel.explain(risk, band, groups, user.Persistent)
		self:_record(user, {
			Time = now,
			WallTime = self._clock.Wall(),
			Type = "Band",
			Risk = risk,
			Band = band,
			Note = `{previousBand} -> {band}`,
		})
		local raised = RiskModel.bandIndex(band) > RiskModel.bandIndex(previousBand)
		local fields = { UserId = user.UserId, Risk = math.floor(risk * 10 + 0.5) / 10, From = previousBand, To = band }
		if raised and RiskModel.bandIndex(band) >= RiskModel.bandIndex("Investigation") then
			self._logger:Warn("Risk band raised", fields)
		else
			self._logger:Info(if raised then "Risk band raised" else "Risk band lowered", fields)
		end
		self._bus:Publish(Topics.RiskChanged, table.freeze({
			UserId = user.UserId,
			Session = self._registry:GetSession(user.UserId),
			Risk = risk,
			Previous = previous,
			Band = band,
			PreviousBand = previousBand,
			Confidence = confidence,
			Explanation = explanation,
		}))
	end
end

function RiskEngine._onDetection(self: RiskEngine, payload: any)
	if not self._running then
		return
	end
	local event = payload.Event
	local settings = self._settings
	local now = self._clock.Now()
	local user = self:_user(event.UserId)
	local name = `{event.Detector}.{event.Kind}`
	local key = user.Keys[name]
	if key == nil then
		if user.KeyCount >= settings.MaxKeysPerUser then
			-- Evict the weakest key; bounded memory per user.
			local weakestName, weakestScore = nil, math.huge
			for otherName, other in user.Keys do
				RiskModel.age(other, now, settings.HalfLifeSeconds)
				if other.Score < weakestScore then
					weakestName, weakestScore = otherName, other.Score
				end
			end
			if weakestName then
				user.Keys[weakestName] = nil
				user.KeyCount -= 1
				self._stats.Evicted += 1
			end
		end
		key = {
			Detector = event.Detector,
			Kind = event.Kind,
			Category = event.Category,
			Group = RiskModel.groupFor(event.Detector, event.Kind, event.Category, settings.Groups),
			Score = 0,
			Updated = now,
			Severity = 0,
			Confidence = 0,
			Count = 0,
			Suppressed = 0,
			LastAccepted = -math.huge,
		}
		user.Keys[name] = key
		user.KeyCount += 1
	end
	local current = key :: RiskModel.Key
	RiskModel.age(current, now, settings.HalfLifeSeconds)
	if now - current.LastAccepted < settings.RepeatSuppressSeconds then
		current.Suppressed += 1
		self._stats.Suppressed += 1
		return
	end
	current.LastAccepted = now
	local contribution = RiskModel.add(current, event.Severity, event.Confidence, settings.RepeatCap)
	self._stats.Detections += 1
	self:_evaluate(user, now)
	self:_record(user, {
		Time = now,
		WallTime = event.WallTime,
		Type = "Detection",
		Detector = event.Detector,
		Kind = event.Kind,
		Group = current.Group,
		Contribution = contribution,
		Risk = user.Risk,
		Band = user.Band,
	})
end

-- Sessions and persistence -----------------------------------------------------------

local function storeKey(userId: number): string
	return `Risk_{userId}`
end

function RiskEngine._onSessionStarted(self: RiskEngine, session: any)
	if not self._running then
		return
	end
	local user = self:_user(session.UserId)
	user.InServer = true
	user.SessionId = session.SessionId
	if not self._persist or user.Loaded then
		return
	end
	local sessionId = session.SessionId
	local persistence = self._settings.Persistence
	local store = self._store :: Types.KeyValueStore
	store:Load(persistence.DataStoreName, storeKey(user.UserId), function(ok: boolean, value: any, err: string?)
		self:_onLoaded(user.UserId, sessionId, ok, value, err)
	end)
end

function RiskEngine._onLoaded(self: RiskEngine, userId: number, sessionId: string, ok: boolean, value: any, err: string?)
	local user = self._users[userId]
	if user == nil or user.SessionId ~= sessionId or not user.InServer then
		return -- the player left before the load finished
	end
	if not ok then
		self._stats.LoadFailed += 1
		self._logger:Warn("Risk history could not be loaded; continuing without it", { UserId = userId, Error = err })
		return
	end
	user.Loaded = true
	self._stats.Loaded += 1
	if type(value) ~= "table" or value.Version ~= RECORD_VERSION or type(value.Risk) ~= "number" or type(value.WallTime) ~= "number" then
		return
	end
	user.Stored = value
	local persistence = self._settings.Persistence
	local hours = math.max(0, self._clock.Wall() - value.WallTime) / 3600
	local seeded = math.min(persistence.Cap, math.max(0, value.Risk) * persistence.Weight * 0.5 ^ (hours / persistence.HalfLifeHours))
	if seeded < 0.5 then
		return
	end
	user.Persistent = seeded
	local now = self._clock.Now()
	self:_evaluate(user, now)
	self:_record(user, {
		Time = now,
		WallTime = self._clock.Wall(),
		Type = "History",
		Contribution = seeded,
		Risk = user.Risk,
		Band = user.Band,
		Note = `saved risk {math.floor(value.Risk)} from {math.floor(hours * 10) / 10} h ago`,
	})
end

function RiskEngine._enqueue(self: RiskEngine, userId: number, record: { [string]: any })
	for _, item in self._queue do
		if item.UserId == userId then
			item.Record = record
			item.Attempts = 0
			return
		end
	end
	table.insert(self._queue, { UserId = userId, Record = record, Attempts = 0 })
end

function RiskEngine._onSessionEnded(self: RiskEngine, session: any)
	local user = self._users[session.UserId]
	if user == nil then
		return
	end
	user.InServer = false
	local now = self._clock.Now()
	self:_evaluate(user, now)
	local persistence = self._settings.Persistence
	if not self._persist or user.Risk < persistence.MinRiskToSave then
		return
	end
	local sessions = {}
	local stored = user.Stored
	if stored and type(stored.Sessions) == "table" then
		for _, entry in stored.Sessions do
			table.insert(sessions, entry)
		end
	end
	local top = {}
	for index, group in user.Groups do
		if index > 3 then
			break
		end
		table.insert(top, { Group = group.Group, Score = math.floor(group.Score), Kind = group.Keys[1] and group.Keys[1].Kind or nil })
	end
	table.insert(sessions, {
		WallTime = math.floor(self._clock.Wall()),
		Risk = math.floor(user.Risk),
		Peak = math.floor(user.Peak),
		Band = user.Band,
		Top = top,
	})
	while #sessions > persistence.MaxSessions do
		table.remove(sessions, 1)
	end
	local record = {
		Version = RECORD_VERSION,
		Risk = math.floor(user.Risk * 10) / 10,
		WallTime = math.floor(self._clock.Wall()),
		Sessions = sessions,
	}
	user.Stored = record
	self:_enqueue(user.UserId, record)
end

-- Writes up to `limit` queued records. Failures are re-queued until MaxAttempts.
function RiskEngine._flush(self: RiskEngine, limit: number)
	if not self._persist or #self._queue == 0 then
		return
	end
	local persistence = self._settings.Persistence
	local store = self._store :: Types.KeyValueStore
	local batch = {}
	while #batch < limit and #self._queue > 0 do
		table.insert(batch, table.remove(self._queue, 1) :: QueueItem)
	end
	for _, item in batch do
		item.Attempts += 1
		self._inFlight += 1
		store:Save(persistence.DataStoreName, storeKey(item.UserId), item.Record, function(ok: boolean, err: string?)
			self._inFlight -= 1
			if ok then
				self._stats.Saved += 1
			elseif item.Attempts < persistence.MaxAttempts then
				self._stats.SaveRetries += 1
				self._logger:Warn("Risk save failed; will retry", { UserId = item.UserId, Attempt = item.Attempts, Error = err })
				table.insert(self._queue, item)
			else
				self._stats.SaveFailed += 1
				self._logger:Error("Risk save failed; giving up", { UserId = item.UserId, Attempts = item.Attempts, Error = err })
			end
		end)
	end
end

-- Lifecycle ----------------------------------------------------------------------------

-- Starts tracking. `scheduler` and `cleanup` belong to the framework's run scope.
function RiskEngine.Start(self: RiskEngine, scheduler: any, cleanup: any)
	self._running = true
	local settings = self._settings
	cleanup:Add(scheduler:Every("ACF.RiskRecompute", settings.RecomputeIntervalSeconds, function()
		self:Recompute()
	end))
	if self._persist then
		cleanup:Add(scheduler:Every("ACF.RiskFlush", settings.Persistence.FlushIntervalSeconds, function()
			self:_flush(settings.Persistence.MaxWritesPerFlush)
		end))
		local onShutdown = self._onShutdown
		if onShutdown and not self._shutdownRegistered then
			self._shutdownRegistered = true
			onShutdown(function()
				self:FlushAll()
			end, function(): number
				return self:Pending()
			end)
		end
	end
end

-- Called after sessions have ended on Stop: writes everything queued.
function RiskEngine.Stop(self: RiskEngine)
	self:FlushAll()
	self._running = false
end

function RiskEngine.Destroy(self: RiskEngine)
	self._running = false
	for _, subscription in self._subscriptions do
		subscription:Disconnect()
	end
	table.clear(self._subscriptions)
	table.clear(self._users)
end

function RiskEngine.FlushAll(self: RiskEngine)
	self:_flush(#self._queue)
end

-- Records queued or being written.
function RiskEngine.Pending(self: RiskEngine): number
	return #self._queue + self._inFlight
end

-- Periodic: decays everyone (bands may fall), prunes dead keys and departed users.
function RiskEngine.Recompute(self: RiskEngine)
	local now = self._clock.Now()
	for userId, user in self._users do
		self:_evaluate(user, now)
		for name, key in user.Keys do
			if key.Score < PRUNE_SCORE then
				user.Keys[name] = nil
				user.KeyCount -= 1
			end
		end
		-- A departed user below risk 1 is forgotten even if tiny residual keys remain.
		if not user.InServer and user.Risk < 1 then
			local queued = false
			for _, item in self._queue do
				if item.UserId == userId then
					queued = true
					break
				end
			end
			if not queued then
				self._users[userId] = nil
			end
		end
	end
end

-- Queries --------------------------------------------------------------------------------

export type RiskReport = {
	UserId: number,
	Risk: number,
	Band: string,
	Confidence: number,
	Persistent: number,
	Peak: number,
	Groups: { { Group: string, Score: number, Confidence: number, Kinds: { { [string]: any } } } },
	Explanation: string,
}

function RiskEngine.Get(self: RiskEngine, userId: number): RiskReport
	local user = self._users[userId]
	if user == nil then
		return {
			UserId = userId,
			Risk = 0,
			Band = "Normal",
			Confidence = 0,
			Persistent = 0,
			Peak = 0,
			Groups = {},
			Explanation = "Risk 0 (Normal)",
		}
	end
	self:_evaluate(user, self._clock.Now())
	local groups = {}
	for _, group in user.Groups do
		local kinds = {}
		for _, key in group.Keys do
			table.insert(kinds, {
				Detector = key.Detector,
				Kind = key.Kind,
				Category = key.Category,
				Score = key.Score,
				Count = key.Count,
				Suppressed = key.Suppressed,
				Severity = key.Severity,
				Confidence = key.Confidence,
			})
		end
		table.insert(groups, { Group = group.Group, Score = group.Score, Confidence = group.Confidence, Kinds = kinds })
	end
	return {
		UserId = userId,
		Risk = user.Risk,
		Band = user.Band,
		Confidence = user.Confidence,
		Persistent = user.Persistent,
		Peak = user.Peak,
		Groups = groups,
		Explanation = RiskModel.explain(user.Risk, user.Band, user.Groups, user.Persistent),
	}
end

function RiskEngine.GetHistory(self: RiskEngine, userId: number): { HistoryEntry }
	local user = self._users[userId]
	if user == nil then
		return {}
	end
	local list = {}
	for _, entry in user.History do
		table.insert(list, table.freeze(table.clone(entry)))
	end
	return list
end

-- Clears a user's risk (staff override). With options.Persistent, the saved record is
-- also cleared (a Risk 0 record that keeps the session list, for audit).
function RiskEngine.Reset(self: RiskEngine, userId: number, options: { Persistent: boolean?, Reason: string? }?)
	local opts: { Persistent: boolean?, Reason: string? } = options or { Persistent = nil, Reason = nil }
	local user = self:_user(userId)
	table.clear(user.Keys)
	user.KeyCount = 0
	user.Persistent = 0
	user.Peak = 0
	local now = self._clock.Now()
	self:_evaluate(user, now)
	self:_record(user, {
		Time = now,
		WallTime = self._clock.Wall(),
		Type = "Reset",
		Risk = user.Risk,
		Band = user.Band,
		Note = opts.Reason,
	})
	self._logger:Info("Risk reset", { UserId = userId, Persistent = opts.Persistent == true, Reason = opts.Reason })
	if opts.Persistent and self._persist then
		local stored = user.Stored
		local record = {
			Version = RECORD_VERSION,
			Risk = 0,
			WallTime = math.floor(self._clock.Wall()),
			Sessions = if stored and type(stored.Sessions) == "table" then stored.Sessions else {},
			ResetReason = opts.Reason,
		}
		user.Stored = record
		self:_enqueue(userId, record)
	end
end

function RiskEngine.GetStats(self: RiskEngine): { [string]: any }
	local tracked, elevated = 0, 0
	for _, user in self._users do
		tracked += 1
		if user.Band ~= "Normal" then
			elevated += 1
		end
	end
	local stats = table.clone(self._stats) :: { [string]: any }
	stats.Tracked = tracked
	stats.Elevated = elevated
	stats.Persistence = self._persist
	stats.Queued = #self._queue
	stats.InFlight = self._inFlight
	return stats
end

return RiskEngine
