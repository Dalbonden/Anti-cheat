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
	local character = Fakes.instance("Model", self.Name)
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

-- Roblox value stand-ins ---------------------------------------------------------------
-- In Roblox (Studio test runs) these return real engine objects. Under Lune they return
-- tables whose metatable __type makes the harness typeof report the engine type name.

local IS_ROBLOX = (Instance :: any) ~= nil

local CLASS_PARENTS = {
	RemoteEvent = "BaseRemoteEvent",
	UnreliableRemoteEvent = "BaseRemoteEvent",
	Model = "PVInstance",
	Part = "BasePart",
	BasePart = "PVInstance",
}

local FakeInstanceMethods = {}
local FakeInstanceMeta = { __type = "Instance", __index = FakeInstanceMethods }

function FakeInstanceMethods:IsA(className)
	local current = self.ClassName
	while current do
		if current == className then
			return true
		end
		current = CLASS_PARENTS[current]
	end
	return className == "Instance"
end

function FakeInstanceMethods:IsDescendantOf(ancestor)
	local node = self.Parent
	while node do
		if node == ancestor then
			return true
		end
		node = node.Parent
	end
	return false
end

function FakeInstanceMethods:GetChildren()
	return table.clone(self._children)
end

function FakeInstanceMethods:GetDescendants()
	local result = {}
	local function walk(node)
		for _, child in node._children do
			table.insert(result, child)
			walk(child)
		end
	end
	walk(self)
	return result
end

function FakeInstanceMethods:FindFirstChild(name)
	for _, child in self._children do
		if child.Name == name then
			return child
		end
	end
	return nil
end

function FakeInstanceMethods:GetAttribute(name)
	return self._attributes[name]
end

function FakeInstanceMethods:SetAttribute(name, value)
	self._attributes[name] = value
end

function FakeInstanceMethods:GetFullName()
	return self.Name
end

-- Creates an Instance (real in Roblox, fake under Lune) parented to `parent`.
function Fakes.instance(className: string, name: string?, parent: any?)
	if IS_ROBLOX then
		local real = Instance.new(className)
		real.Name = name or className
		real.Parent = parent
		return real
	end
	local fake = setmetatable({
		Name = name or className,
		ClassName = className,
		Parent = parent,
		_children = {},
		_attributes = {},
	}, FakeInstanceMeta)
	if className == "RemoteEvent" or className == "UnreliableRemoteEvent" then
		fake.OnServerEvent = Signal.new()
	end
	if parent then
		table.insert(parent._children, fake)
	end
	return fake
end

function Fakes.vector3(x: number, y: number, z: number)
	if IS_ROBLOX then
		return Vector3.new(x, y, z)
	end
	return setmetatable({ X = x, Y = y, Z = z, Magnitude = math.sqrt(x * x + y * y + z * z) }, { __type = "Vector3" })
end

function Fakes.cframe(x: number, y: number, z: number)
	if IS_ROBLOX then
		return CFrame.new(x, y, z)
	end
	return setmetatable({
		Position = Fakes.vector3(x, y, z),
		GetComponents = function()
			return x, y, z, 1, 0, 0, 0, 1, 0, 0, 0, 1
		end,
	}, { __type = "CFrame" })
end

-- Fireable remotes. Always fakes: a real RemoteEvent's OnServerEvent cannot be fired from
-- the server, so tests simulate client requests through these.
local function fakeRemote(className: string, name: string?)
	local remote = {
		Name = name or className,
		ClassName = className,
		OnServerEvent = if className ~= "RemoteFunction" then Signal.new() else nil,
		OnServerInvoke = nil,
	}
	function remote.IsA(_self, query)
		return FakeInstanceMethods.IsA(remote, query)
	end
	return remote
end

function Fakes.remoteEvent(name: string?)
	return fakeRemote("RemoteEvent", name)
end

function Fakes.unreliableRemoteEvent(name: string?)
	return fakeRemote("UnreliableRemoteEvent", name)
end

function Fakes.remoteFunction(name: string?)
	return fakeRemote("RemoteFunction", name)
end

-- Simulates a client firing a remote event: remote.OnServerEvent fires with (player, ...).
function Fakes.fire(remote, player, ...)
	remote.OnServerEvent:Fire(player, ...)
end

-- Simulates a client invoking a RemoteFunction. Returns what the server callback returns.
-- With no callback set, Roblox would leave the client yielding; we report that as an error.
function Fakes.invoke(remote, player, ...)
	local callback = remote.OnServerInvoke
	if callback == nil then
		error("RemoteFunction has no OnServerInvoke (client would yield forever)")
	end
	return callback(player, ...)
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
