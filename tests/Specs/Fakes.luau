--[[
	Test doubles for the platform side of ACF's Environment: signals, players, the
	Players service, a controllable clock, deterministic ids and a capturing log sink.

	These replace Roblox services only. ACF logic under test is always the real code.
]]

local Fakes = {}

-- Sentinel for "remove this field" in merge-style helpers (nil cannot express it).
Fakes.NONE = table.freeze({})

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

-- Physics world ----------------------------------------------------------------------
-- A world of axis-aligned boxes with real ray casting, plus scripted character samples.
-- Samples default to a healthy, standing R15-like character; GroundClearance is computed
-- from the boxes below the feet unless a test sets it explicitly.

local STANDING_HEIGHT = 3

local DEFAULT_SAMPLE = {
	X = 0,
	Y = STANDING_HEIGHT,
	Z = 0,
	VX = 0,
	VY = 0,
	VZ = 0,
	AngularSpeed = 0,
	WalkSpeed = 16,
	JumpVelocity = 50,
	Gravity = 196.2,
	State = "Running",
	Seated = false,
	Health = 100,
	Ping = 0.05,
}

local function rayBox(ox, oy, oz, dx, dy, dz, box)
	-- Like Roblox: a ray that starts inside a part does not hit that part.
	if ox > box.min[1] and ox < box.max[1] and oy > box.min[2] and oy < box.max[2] and oz > box.min[3] and oz < box.max[3] then
		return nil
	end
	local tmin, tmax = 0, 1
	for axis = 1, 3 do
		local o = if axis == 1 then ox elseif axis == 2 then oy else oz
		local d = if axis == 1 then dx elseif axis == 2 then dy else dz
		local lo, hi = box.min[axis], box.max[axis]
		if math.abs(d) < 1e-9 then
			if o < lo or o > hi then
				return nil
			end
		else
			local t1, t2 = (lo - o) / d, (hi - o) / d
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			tmin = math.max(tmin, t1)
			tmax = math.min(tmax, t2)
			if tmin > tmax then
				return nil
			end
		end
	end
	return tmin
end

function Fakes.physics()
	local physics = { Casts = 0, Samples = 0, _boxes = {}, _samples = {} }

	-- Adds a solid box spanning (x1,y1,z1)-(x2,y2,z2).
	function physics.AddBox(_self, x1, y1, z1, x2, y2, z2)
		table.insert(physics._boxes, {
			min = { math.min(x1, x2), math.min(y1, y2), math.min(z1, z2) },
			max = { math.max(x1, x2), math.max(y1, y2), math.max(z1, z2) },
		})
	end

	-- A large floor whose top surface is y = 0.
	function physics.AddFloor(self)
		self:AddBox(-100000, -10, -100000, 100000, 0, 100000)
	end

	-- Sets (merges) the character's next sample. nil fields keep previous values.
	function physics.Set(_self, character, fields)
		local current = physics._samples[character]
		if current == nil then
			current = table.clone(DEFAULT_SAMPLE)
			physics._samples[character] = current
		end
		for key, value in fields do
			current[key] = value
		end
	end

	function physics.Clear(_self, character)
		physics._samples[character] = nil
	end

	-- Hit targets: physics:SetTarget(part, { X, Y, Z, Model?, Player?, Alive?, IsHead? }).
	physics._targets = {}
	function physics.SetTarget(_self, part, info)
		local entry = table.clone(info)
		if entry.Alive == nil then
			entry.Alive = true
		end
		if entry.IsHead == nil then
			entry.IsHead = false
		end
		physics._targets[part] = entry
	end

	function physics.Describe(_self, part)
		local info = physics._targets[part]
		return if info then table.clone(info) else nil
	end

	-- Enforcement correction: moves the scripted character. Records each call.
	physics.Corrections = {}
	function physics.Correct(self, character, x, y, z)
		table.insert(physics.Corrections, { X = x, Y = y, Z = z })
		self:Set(character, { X = x, Y = y, Z = z, VX = 0, VY = 0, VZ = 0 })
	end

	function physics.Cast(_self, ox, oy, oz, dx, dy, dz, _character)
		physics.Casts += 1
		local length = math.sqrt(dx * dx + dy * dy + dz * dz)
		local best = nil
		for _, box in physics._boxes do
			local t = rayBox(ox, oy, oz, dx, dy, dz, box)
			if t and (best == nil or t < best) then
				best = t
			end
		end
		return if best then best * length else nil
	end

	function physics.Sample(self, character, _player)
		local current = physics._samples[character]
		if current == nil then
			return nil
		end
		physics.Samples += 1
		local sample = table.clone(current)
		if sample.GroundClearance == nil then
			local feet = sample.Y - STANDING_HEIGHT
			local distance = self:Cast(sample.X, feet + 0.01, sample.Z, 0, -64, 0)
			sample.GroundClearance = if distance then math.max(0, distance - 0.01) else math.huge
		end
		return sample
	end

	return physics
end

-- ACF-owned remotes (Environment.Remotes) backed by fireable fakes.
function Fakes.remotes()
	local provider = { Created = {} }
	function provider.GetOrCreate(_self, name, className)
		local existing = provider.Created[name]
		if existing then
			return existing
		end
		local remote = if className == "RemoteFunction" then Fakes.remoteFunction(name) else Fakes.remoteEvent(name)
		provider.Created[name] = remote
		return remote
	end
	return provider
end

-- Environment ------------------------------------------------------------------------

-- Returns env plus handles: { Env, Players, Clock, Heartbeat, Physics, Remotes, Logs }.
-- Logs captures every emitted entry; nothing is printed.
-- In-memory Environment.Store. `Deferred = true` holds callbacks until Complete(), to
-- model DataStore latency; FailLoads / FailSaves make the next N calls fail.
function Fakes.store()
	local store = {
		Data = {},
		Deferred = false,
		FailLoads = 0,
		FailSaves = 0,
		Loads = 0,
		Saves = 0,
		-- Per DataStore name: { Loads, Saves }.
		ByScope = {},
		_pending = {},
	}
	local function run(fn)
		if store.Deferred then
			table.insert(store._pending, fn)
		else
			fn()
		end
	end
	local function count(scope, field)
		store.ByScope[scope] = store.ByScope[scope] or { Loads = 0, Saves = 0 }
		store.ByScope[scope][field] += 1
	end
	function store.Load(_self, scope, key, callback)
		store.Loads += 1
		count(scope, "Loads")
		run(function()
			if store.FailLoads > 0 then
				store.FailLoads -= 1
				callback(false, nil, "fake load failure")
				return
			end
			local bucket = store.Data[scope]
			callback(true, if bucket then bucket[key] else nil, nil)
		end)
	end
	function store.Save(_self, scope, key, value, callback)
		store.Saves += 1
		count(scope, "Saves")
		run(function()
			if store.FailSaves > 0 then
				store.FailSaves -= 1
				callback(false, "fake save failure")
				return
			end
			store.Data[scope] = store.Data[scope] or {}
			store.Data[scope][key] = value
			callback(true, nil)
		end)
	end
	-- Runs held callbacks (in order). Returns how many ran.
	function store.Complete()
		local pending = store._pending
		store._pending = {}
		for _, fn in pending do
			fn()
		end
		return #pending
	end
	return store
end

-- Environment.Enforcer that records calls. Kick makes the player leave, like Roblox.
function Fakes.enforcer(players)
	local enforcer = { Kicks = {}, Bans = {}, Unbans = {}, FailBans = 0 }
	function enforcer.Kick(_self, player, message)
		table.insert(enforcer.Kicks, { UserId = player.UserId, Message = message })
		players:Leave(player)
	end
	function enforcer.Ban(_self, userId, seconds, displayReason, privateReason, callback)
		table.insert(enforcer.Bans, { UserId = userId, Seconds = seconds, Display = displayReason, Private = privateReason })
		if enforcer.FailBans > 0 then
			enforcer.FailBans -= 1
			callback(false, "fake ban api failure")
		else
			callback(true, nil)
		end
	end
	function enforcer.Unban(_self, userId, callback)
		table.insert(enforcer.Unbans, userId)
		callback(true, nil)
	end
	return enforcer
end

function Fakes.environment(options: { Heartbeat: boolean?, PrintLogs: boolean?, Store: any?, ClockStart: number? }?)
	local opts = options or {}
	local players = Fakes.players()
	local clock = Fakes.clock(opts.ClockStart)
	local heartbeat = if opts.Heartbeat then Signal.new() else nil
	local physics = Fakes.physics()
	local remotes = Fakes.remotes()
	local logs = {}
	local counter = 0
	local store = opts.Store or Fakes.store()
	local hooks = {}
	-- Like BindToClose: every registration runs at shutdown.
	local shutdown = {
		Flush = function()
			for _, hook in hooks do
				hook.flush()
			end
		end,
		Pending = function()
			local total = 0
			for _, hook in hooks do
				total += hook.pending()
			end
			return total
		end,
		Hooks = hooks,
	}
	local enforcer = Fakes.enforcer(players)
	local env = {
		Store = store,
		Enforcer = enforcer,
		OnShutdown = function(flush, pending)
			table.insert(hooks, { flush = flush, pending = pending })
		end,
		Players = players,
		Heartbeat = heartbeat,
		Physics = physics,
		Remotes = remotes,
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
		Physics = physics,
		Remotes = remotes,
		Logs = logs,
		Store = store,
		-- Flush() runs every shutdown hook; Pending() sums them.
		Shutdown = shutdown,
		Enforcer = enforcer,
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
