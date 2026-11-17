--[[
	Shared combat test arena. A shooter stands at (0,3,0) holding the weapons it is given;
	a victim stands at (x,3,0). Parts are registered as hit targets in the fake physics.
]]

local ACF = game:GetService("ServerScriptService").ACF
local Framework = require(ACF.Core.Framework)
local Fakes = require(script.Parent.Parent.Fakes)

local Harness = {}

function Harness.arena(options)
	local opts = options or {}
	local fake = Fakes.environment()
	fake.Physics:AddFloor()
	local framework = Framework.new(fake.Env)
	framework:Initialize(opts.Config or {})
	local combat = framework:GetModule("Combat")
	for id, definition in opts.Weapons or {} do
		combat:Define(id, definition)
	end
	framework:Start()

	local shooter = fake.Players:Join(Fakes.player(1, "Shooter"))
	local shooterCharacter = shooter:Spawn()
	fake.Physics:Set(shooterCharacter, { X = 0, Y = 3, Z = 0 })
	for id in opts.Weapons or {} do
		if opts.Owned == nil or table.find(opts.Owned, id) then
			Fakes.instance("Tool", id, shooterCharacter)
		end
	end

	local victim = fake.Players:Join(Fakes.player(2, "Victim"))
	local victimCharacter = victim:Spawn()
	local distance = opts.VictimDistance or 50
	fake.Physics:Set(victimCharacter, { X = distance, Y = 3, Z = 0 })
	local torso = Fakes.instance("Part", "UpperTorso", victimCharacter)
	local head = Fakes.instance("Part", "Head", victimCharacter)
	fake.Physics:SetTarget(torso, { X = distance, Y = 3, Z = 0, Model = victimCharacter, Player = victim })
	fake.Physics:SetTarget(head, { X = distance, Y = 4.5, Z = 0, Model = victimCharacter, Player = victim, IsHead = true })

	local arena = {
		framework = framework,
		fake = fake,
		combat = combat,
		shooter = shooter,
		shooterCharacter = shooterCharacter,
		victim = victim,
		victimCharacter = victimCharacter,
		torso = torso,
		head = head,
		distance = distance,
	}

	-- Moves the victim (and its hit parts) to x.
	function arena.moveVictim(x)
		arena.distance = x
		fake.Physics:Set(victimCharacter, { X = x })
		fake.Physics:SetTarget(torso, { X = x, Y = 3, Z = 0, Model = victimCharacter, Player = victim })
		fake.Physics:SetTarget(head, { X = x, Y = 4.5, Z = 0, Model = victimCharacter, Player = victim, IsHead = true })
	end

	function arena.claim(fields)
		local claim = { Origin = Fakes.vector3(0, 4.5, 0), Target = torso, HitPosition = Fakes.vector3(arena.distance, 3, 0) }
		for k, v in fields or {} do
			if v == Fakes.NONE then
				claim[k] = nil
			else
				claim[k] = v
			end
		end
		return claim
	end

	function arena.advance(seconds)
		fake.Clock.Advance(seconds)
		framework:Step()
	end

	function arena.kinds()
		local kinds = {}
		for _, record in framework:GetEvidence(shooter) do
			if record.Category == "Combat" then
				kinds[record.Kind] = record
			end
		end
		return kinds
	end

	function arena.combatEvidence()
		local list = {}
		for _, record in framework:GetEvidence(shooter) do
			if record.Category == "Combat" then
				table.insert(list, record.Kind)
			end
		end
		return list
	end

	return arena
end

Harness.RIFLE = {
	Kind = "Hitscan",
	Damage = 25,
	HeadshotMultiplier = 2,
	FireRate = 10,
	MaxRange = 300,
	Ammo = { Magazine = 30, Reserve = 90, ReloadSeconds = 2 },
}

Harness.SWORD = { Kind = "Melee", Damage = 30, FireRate = 2, MaxRange = 8 }

Harness.ROCKET = {
	Kind = "Projectile",
	Damage = 80,
	FireRate = 1,
	MaxRange = 500,
	ProjectileSpeed = 100,
	ProjectileLifetime = 6,
}

Harness.FIREBALL = { Kind = "Ability", Damage = 40, Cooldown = 5, MaxRange = 60 }

return Harness
