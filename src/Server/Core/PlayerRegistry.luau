--!strict
--[[
	Player session registry.

	Creates one Session per player per join and ends it when the player leaves. A rejoin
	creates a new session with a new SessionId. Sessions track the current character and
	a CharacterGeneration counter that increments on every spawn. Later phases use that
	counter to discard movement samples that straddle a respawn.

	Each session owns a Cleanup bag that is cleaned when the session ends, so modules can
	attach per-player connections without tracking them themselves.

	Published topics: PlayerSessionStarted, PlayerSessionEnded, CharacterSpawned,
	CharacterRemoving. PlayerSessionEnded is published before the session's Cleanup runs,
	so subscribers can still read session state.
]]

local Cleanup = require(script.Parent.Cleanup)
local EventBus = require(script.Parent.EventBus)
local Logger = require(script.Parent.Logger)
local Topics = require(script.Parent.Topics)
local Types = require(script.Parent.Parent.Types)

-- Session ------------------------------------------------------------------------------

local Session = {}
Session.__index = Session

export type Session = typeof(setmetatable(
	{} :: {
		SessionId: string,
		UserId: number,
		Name: string,
		Player: Types.PlayerLike,
		JoinedAt: number,
		JoinedWallTime: number,
		Character: any?,
		CharacterGeneration: number,
		Active: boolean,
		Cleanup: Cleanup.Cleanup,
		_state: { [string]: any },
	},
	Session
))

-- Per-session scratch state keyed by owner (normally a module name). Created on first
-- access by `factory`. Freed automatically when the session ends.
function Session.GetState(self: Session, key: string, factory: (() -> any)?): any
	local value = self._state[key]
	if value == nil and factory then
		value = factory()
		self._state[key] = value
	end
	return value
end

function Session.ClearState(self: Session, key: string)
	self._state[key] = nil
end

-- Registry ---------------------------------------------------------------------------

local PlayerRegistry = {}
PlayerRegistry.__index = PlayerRegistry

export type PlayerRegistry = typeof(setmetatable(
	{} :: {
		_players: Types.PlayersLike,
		_bus: EventBus.EventBus,
		_logger: Logger.Logger,
		_clock: Types.Clock,
		_generateId: () -> string,
		_byUserId: { [number]: Session },
		_connections: Cleanup.Cleanup,
		_running: boolean,
		_started: number,
		_ended: number,
	},
	PlayerRegistry
))

export type PlayerRegistryOptions = {
	Players: Types.PlayersLike,
	Bus: EventBus.EventBus,
	Logger: Logger.Logger,
	Clock: Types.Clock,
	GenerateId: () -> string,
}

function PlayerRegistry.new(options: PlayerRegistryOptions): PlayerRegistry
	local logger = options.Logger
	return setmetatable({
		_players = options.Players,
		_bus = options.Bus,
		_logger = logger,
		_clock = options.Clock,
		_generateId = options.GenerateId,
		_byUserId = {},
		_connections = Cleanup.new(function(message)
			logger:Error("Registry connection cleanup failed", { Error = message })
		end),
		_running = false,
		_started = 0,
		_ended = 0,
	}, PlayerRegistry)
end

local function onCharacterAdded(self: PlayerRegistry, session: Session, character: any)
	if not session.Active then
		return
	end
	session.Character = character
	session.CharacterGeneration += 1
	self._bus:Publish(Topics.CharacterSpawned, {
		Session = session,
		Character = character,
		Generation = session.CharacterGeneration,
	})
end

local function onCharacterRemoving(self: PlayerRegistry, session: Session, character: any)
	if not session.Active then
		return
	end
	self._bus:Publish(Topics.CharacterRemoving, {
		Session = session,
		Character = character,
		Generation = session.CharacterGeneration,
	})
	if session.Character == character then
		session.Character = nil
	end
end

local function beginSession(self: PlayerRegistry, player: Types.PlayerLike)
	local userId = player.UserId
	if type(userId) ~= "number" then
		self._logger:Error("Ignoring player without numeric UserId")
		return
	end
	local existing = self._byUserId[userId]
	if existing then
		if existing.Player == player then
			return -- duplicate PlayerAdded (e.g. raced with the initial GetPlayers pass)
		end
		-- Same UserId on a different Player object: the old one never got
		-- PlayerRemoving. End it so state cannot leak across sessions.
		self._logger:Warn("Replacing stale session for rejoining user", { UserId = userId })
		self:EndSession(userId)
	end

	local logger = self._logger
	local session: Session = setmetatable({
		SessionId = self._generateId(),
		UserId = userId,
		Name = tostring(player.Name),
		Player = player,
		JoinedAt = self._clock.Now(),
		JoinedWallTime = self._clock.Wall(),
		Character = nil,
		CharacterGeneration = 0,
		Active = true,
		Cleanup = Cleanup.new(function(message)
			logger:Error("Session cleanup task failed", { UserId = userId, Error = message })
		end),
		_state = {},
	}, Session)
	self._byUserId[userId] = session
	self._started += 1

	session.Cleanup:Add(player.CharacterAdded:Connect(function(character)
		onCharacterAdded(self, session, character)
	end))
	session.Cleanup:Add(player.CharacterRemoving:Connect(function(character)
		onCharacterRemoving(self, session, character)
	end))

	self._logger:Debug("Session started", { UserId = userId, SessionId = session.SessionId })
	self._bus:Publish(Topics.PlayerSessionStarted, { Session = session })

	local character = player.Character
	if character ~= nil and session.Active and session.Character == nil then
		onCharacterAdded(self, session, character)
	end
end

function PlayerRegistry.Start(self: PlayerRegistry)
	if self._running then
		return
	end
	self._running = true
	local players = self._players
	self._connections:Add(players.PlayerAdded:Connect(function(player)
		beginSession(self, player)
	end))
	self._connections:Add(players.PlayerRemoving:Connect(function(player)
		local session = self._byUserId[player.UserId]
		if session and session.Player == player then
			self:EndSession(player.UserId)
		end
	end))
	for _, player in players:GetPlayers() do
		beginSession(self, player)
	end
end

-- Stops tracking and ends every active session.
function PlayerRegistry.Stop(self: PlayerRegistry)
	if not self._running then
		return
	end
	self._running = false
	self._connections:Clean()
	local userIds = {}
	for userId in self._byUserId do
		table.insert(userIds, userId)
	end
	for _, userId in userIds do
		self:EndSession(userId)
	end
end

function PlayerRegistry.EndSession(self: PlayerRegistry, userId: number)
	local session: Session? = self._byUserId[userId]
	if session == nil then
		return
	end
	self._byUserId[userId] = nil
	self._bus:Publish(Topics.PlayerSessionEnded, { Session = session })
	session.Active = false
	session.Cleanup:Clean()
	table.clear(session._state)
	session.Character = nil
	self._ended += 1
	self._logger:Debug("Session ended", { UserId = userId, SessionId = session.SessionId })
end

-- Accepts a Player, a UserId or a Session. Returns the active session or nil.
function PlayerRegistry.GetSession(self: PlayerRegistry, target: any): Session?
	local kind = type(target)
	if kind == "number" then
		return self._byUserId[target]
	end
	if target == nil then
		return nil
	end
	if getmetatable(target) == Session then
		local session = target :: Session
		if session.Active and self._byUserId[session.UserId] == session then
			return session
		end
		return nil
	end
	local ok, userId = pcall(function()
		return target.UserId
	end)
	if ok and type(userId) == "number" then
		local session = self._byUserId[userId]
		if session and session.Player == target then
			return session
		end
	end
	return nil
end

function PlayerRegistry.GetSessions(self: PlayerRegistry): { Session }
	local list: { Session } = {}
	for _, session in self._byUserId do
		table.insert(list, session)
	end
	table.sort(list, function(a, b)
		return a.JoinedAt < b.JoinedAt
	end)
	return list
end

function PlayerRegistry.Count(self: PlayerRegistry): number
	local n = 0
	for _ in self._byUserId do
		n += 1
	end
	return n
end

function PlayerRegistry.IsRunning(self: PlayerRegistry): boolean
	return self._running
end

function PlayerRegistry.GetStats(self: PlayerRegistry): { Active: number, Started: number, Ended: number }
	return { Active = self:Count(), Started = self._started, Ended = self._ended }
end

PlayerRegistry.Session = Session

return PlayerRegistry
