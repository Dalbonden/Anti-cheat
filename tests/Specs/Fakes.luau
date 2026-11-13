--[[
	Test doubles for the platform side of ACF's Environment: signals, players, the
	Players service, a controllable clock, deterministic ids and a capturing log sink.

	These replace Roblox services only. ACF logic under test is always the real code.
]]

local Fakes = {}

-- Signal -----------------------------------------------------------------------------

local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({ _handlers = {} }, Signal)
end

function Signal:Connect(handler)
	local connection = { Connected = true }
	local handlers = self._handlers
	function connection.Disconnect()
		connection.Connected = false
		local index = table.find(handlers, connection)
		if index then
			table.remove(handlers, index)
		end
	end
	connection.Handler = handler
	table.insert(handlers, connection)
	return connection
end

function Signal:Fire(...)
	for _, connection in table.clone(self._handlers) do
		if connection.Connected then
			connection.Handler(...)
		end
	end
end

function Signal:ConnectionCount()
	return #self._handlers
end

Fakes.Signal = Signal

-- Player -----------------------------------------------------------------------------

local Player = {}
Player.__index = Player

function Fakes.player(userId: number, name: string?)
	return setmetatable({
		UserId = userId,
		Name = name or `Player{userId}`,
		Character = nil,
		CharacterAdded = Signal.new(),
		CharacterRemoving = Signal.new(),
		Kicked = nil,
		_children = {},
	}, Player)
end

function Player:Spawn()
	if self.Character then
		self:Despawn()
	end
	local character = { Name = self.Name, IsFakeCharacter = true }
	self.Character = character
	self.CharacterAdded:Fire(character)
	return character
end

function Player:Despawn()
	local character = self.Character
	if character then
		self.CharacterRemoving:Fire(character)
		self.Character = nil
	end
end

function Player:Kick(message: string?)
	self.Kicked = message or ""
end

function Player:FindFirstChild(name: string)
	return self._children[name]
end

function Player:SetChild(name: string, value: any)
	self._children[name] = value
end

-- Players service --------------------------------------------------------------------

function Fakes.players()
	local service = {
		PlayerAdded = Signal.new(),
		PlayerRemoving = Signal.new(),
		_list = {},
	}
	function service.GetPlayers(_self)
		return table.clone(service._list)
	end
	function service.Join(_self, player)
		table.insert(service._list, player)
		service.PlayerAdded:Fire(player)
		return player
	end
	function service.Leave(_self, player)
		service.PlayerRemoving:Fire(player)
		local index = table.find(service._list, player)
		if index then
			table.remove(service._list, index)
		end
	end
	-- Adds a player without firing PlayerAdded (simulates players present before ACF starts).
	function service.Preload(_self, player)
		table.insert(service._list, player)
		return player
	end
	return service
end

-- Clock ------------------------------------------------------------------------------

function Fakes.clock(start: number?)
	local now = start or 1000
	local clock = {}
	clock.Now = function()
		return now
	end
	clock.Wall = function()
		return 1700000000 + now
	end
	clock.Advance = function(seconds: number)
		now += seconds
	end
	return clock
end

-- Environment ------------------------------------------------------------------------

-- Returns env plus handles for driving it: { Env, Players, Clock, Heartbeat, Logs }.
-- Logs captures every emitted entry; nothing is printed.
function Fakes.environment(options: { Heartbeat: boolean?, PrintLogs: boolean? }?)
	local opts = options or {}
	local players = Fakes.players()
	local clock = Fakes.clock()
	local heartbeat = if opts.Heartbeat then Signal.new() else nil
	local logs = {}
	local counter = 0
	local env = {
		Players = players,
		Heartbeat = heartbeat,
		Clock = { Now = clock.Now, Wall = clock.Wall },
		GenerateId = function()
			counter += 1
			return string.format("id-%06d", counter)
		end,
		LogSink = function(entry)
			table.insert(logs, entry)
			if opts.PrintLogs then
				print(entry.Level, entry.Scope, entry.Message)
			end
		end,
	}
	return {
		Env = env,
		Players = players,
		Clock = clock,
		Heartbeat = heartbeat,
		Logs = logs,
	}
end

-- Finds captured log entries whose message contains `text`.
function Fakes.findLogs(logs, text: string, level: string?)
	local found = {}
	for _, entry in logs do
		if string.find(entry.Message, text, 1, true) and (level == nil or entry.Level == level) then
			table.insert(found, entry)
		end
	end
	return found
end

-- A minimal valid module definition that records its lifecycle calls.
function Fakes.module(name: string, overrides: { [string]: any }?)
	local calls = {}
	local definition = {
		Name = name,
		Calls = calls,
		Context = nil,
	}
	function definition:Initialize(context)
		table.insert(calls, "Initialize")
		self.Context = context
	end
	function definition:Start()
		table.insert(calls, "Start")
	end
	function definition:Stop()
		table.insert(calls, "Stop")
	end
	function definition:Destroy()
		table.insert(calls, "Destroy")
	end
	for key, value in overrides or {} do
		definition[key] = value
	end
	return definition
end

return Fakes
