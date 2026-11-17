--[[
	Micro-benchmarks for hot paths (Lune). Numbers are indicative only: Lune's Luau VM
	is not Roblox's server, but relative costs and regressions show up reliably.

		./.bin/lune.exe run tests/lune/bench.luau
]]

local process = require("@lune/process")
local VirtualDataModel = require("./VirtualDataModel")

local root = process.cwd
local game, requireModule = VirtualDataModel.load(root .. "/test.project.json", root)
local ACF = game.ServerScriptService.ACF
local Framework = requireModule(ACF.Core.Framework)
local V = requireModule(ACF.Detection.RemoteSecurity.Validators)
local Fakes = requireModule(game.ServerStorage.ACFTests.Fakes)

local function bench(name: string, iterations: number, fn: () -> ())
	for _ = 1, math.min(1000, iterations) do
		fn()
	end
	local started = os.clock()
	for _ = 1, iterations do
		fn()
	end
	local elapsed = os.clock() - started
	print(string.format("%-46s %9.2f us/op  (%d ops)", name, elapsed / iterations * 1e6, iterations))
end

local fake = Fakes.environment()
local framework = Framework.new(fake.Env)
framework:Initialize({})
framework:Start()
local security = framework:GetModule("RemoteSecurity")
local player = fake.Players:Join(Fakes.player(1))

local buy = Fakes.remoteEvent("Buy")
security:ProtectEvent(buy, {
	Arguments = { V.string({ MaxLength = 32 }), V.integer({ Min = 1, Max = 99 }) },
	RateLimit = { Burst = 1e9, PerSecond = 1e9 },
	Handler = function() end,
})

local inventory = Fakes.remoteEvent("Inventory")
security:ProtectEvent(inventory, {
	Arguments = { V.array(V.struct({ Id = V.string({ MaxLength = 16 }), Count = V.integer() }), { MaxLength = 32 }) },
	RateLimit = { Burst = 1e9, PerSecond = 1e9 },
	Handler = function() end,
})
local items = {}
for i = 1, 32 do
	items[i] = { Id = "item" .. i, Count = i }
end

local flooded = Fakes.remoteEvent("Flooded")
security:ProtectEvent(flooded, {
	Arguments = {},
	RateLimit = { Burst = 1, PerSecond = 0.001 },
	Handler = function() end,
})

local huge = table.create(100000, 1)

bench("accepted request (2 scalar args)", 200000, function()
	Fakes.fire(buy, player, "Sword", 3)
end)
bench("accepted request (array of 32 structs)", 50000, function()
	Fakes.fire(inventory, player, items)
end)
bench("rejected: invalid argument", 200000, function()
	Fakes.fire(buy, player, "Sword", -1)
end)
bench("rejected: rate limited (flood)", 200000, function()
	Fakes.fire(flooded, player)
end)
bench("rejected: 100k-element table (bounded walk)", 20000, function()
	Fakes.fire(inventory, player, huge)
end)

local evidence = framework:GetEvidenceSummary(player)
print(string.format("\nevidence records after flood: %d (merged %d)", evidence.Records, evidence.Merged))

-- Movement + Physics: one scheduler tick sampling 50 walking players (fake probe/world).
local mfake = Fakes.environment()
mfake.Physics:AddFloor()
mfake.Physics:AddBox(500, 0, -1000, 502, 20, 1000) -- a wall, so noclip casts do work
local mframework = Framework.new(mfake.Env)
mframework:Initialize({ ModuleSettings = { Movement = { SampleIntervalSeconds = 0.2 } } })
mframework:Start()
local characters = {}
for i = 1, 50 do
	local p = mfake.Players:Join(Fakes.player(1000 + i))
	local c = p:Spawn()
	mfake.Physics:Set(c, { X = 0, Z = i * 5 })
	characters[i] = c
end
local step = 0
bench("movement tick, 50 players (per tick)", 2000, function()
	step += 1
	for i, c in characters do
		mfake.Physics:Set(c, { X = step * 3.2, Z = i * 5, VX = 16 })
	end
	mfake.Clock.Advance(0.2)
	mframework:Step()
end)
print(string.format("  -> %d fake probe samples, %d ray casts", mfake.Physics.Samples, mfake.Physics.Casts))

-- Combat: one validated hitscan hit (shot + hit checks + line-of-sight cast).
local cfake = Fakes.environment()
cfake.Physics:AddFloor()
local cframework = Framework.new(cfake.Env)
cframework:Initialize({})
local combat = cframework:GetModule("Combat")
combat:Define("Rifle", { Kind = "Hitscan", Damage = 25, FireRate = 1e6, Burst = 1e6, MaxRange = 500 })
combat:Define("Rocket", { Kind = "Projectile", Damage = 50, FireRate = 1e6, Burst = 1e6, MaxRange = 500, ProjectileSpeed = 200, ProjectileGravity = 30 })
cframework:Start()
local shooter = cfake.Players:Join(Fakes.player(1))
local shooterCharacter = shooter:Spawn()
cfake.Physics:Set(shooterCharacter, {})
Fakes.instance("Tool", "Rifle", shooterCharacter)
Fakes.instance("Tool", "Rocket", shooterCharacter)
local victim = cfake.Players:Join(Fakes.player(2))
local victimCharacter = victim:Spawn()
local torso = Fakes.instance("Part", "Torso", victimCharacter)
cfake.Physics:SetTarget(torso, { X = 100, Y = 3, Z = 0, Model = victimCharacter, Player = victim })
local claim = { Origin = Fakes.vector3(0, 4.5, 0), Target = torso, HitPosition = Fakes.vector3(100, 3, 0) }
bench("combat: validated hitscan hit", 100000, function()
	combat:ValidateAttack(shooter, "Rifle", claim)
end)
local shot = 0
bench("combat: projectile fire + arcing hit validation", 20000, function()
	shot += 1
	local id = "b" .. shot
	combat:FireProjectile(shooter, "Rocket", { Origin = Fakes.vector3(0, 3, 0), Direction = Fakes.vector3(1, 0, 0), ShotId = id })
	cfake.Clock.Advance(0.6)
	combat:ValidateProjectileHit(shooter, id, { Target = torso })
end)
