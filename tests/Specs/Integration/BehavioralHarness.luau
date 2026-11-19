--[[
	Shared behavioural test world: the full framework with fakes, N players and a
	deterministic random generator (Park-Miller), so every scenario is reproducible in
	Lune and in Studio.

	Players stand at (0, 3, 10 * i). A target dummy (player 100) stands at (50, 3, 0)
	with an UpperTorso and a Head registered as hit targets, for combat accuracy tests.
]]

local ACF = game:GetService("ServerScriptService").ACF
local Framework = require(ACF.Core.Framework)
local Fakes = require(script.Parent.Parent.Fakes)

local Harness = {}

-- Deterministic uniform [0, 1) generator.
function Harness.rng(seed: number)
	local state = seed % 2147483647
	if state <= 0 then
		state += 2147483646
	end
	local function uniform(): number
		state = (state * 16807) % 2147483647
		return (state - 1) / 2147483646
	end
	local rng = {}
	function rng.uniform(): number
		return uniform()
	end
	-- Approximately normal (sum of 12 uniforms).
	function rng.normal(mean: number, std: number): number
		local sum = 0
		for _ = 1, 12 do
			sum += uniform()
		end
		return mean + (sum - 6) * std
	end
	function rng.chance(p: number): boolean
		return uniform() < p
	end
	return rng
end

Harness.RIFLE = { Kind = "Hitscan", Damage = 25, HeadshotMultiplier = 2, FireRate = 10, MaxRange = 300 }

function Harness.world(options)
	local opts = options or {}
	local fake = Fakes.environment()
	fake.Physics:AddFloor()
	local framework = Framework.new(fake.Env)
	framework:Initialize(opts.Config or {})
	local behavioral = framework:GetModuleState("Behavioral") ~= "Disabled" and framework:GetModule("Behavioral") or nil
	for name, signal in opts.Signals or {} do
		behavioral:DefineSignal(name, signal)
	end
	local combat = framework:GetModuleState("Combat") ~= "Disabled" and framework:GetModule("Combat") or nil
	if combat and opts.Combat then
		combat:Define("Rifle", Harness.RIFLE)
	end
	framework:Start()

	local players = {}
	for i = 1, opts.Players or 6 do
		local player = fake.Players:Join(Fakes.player(i, "P" .. i))
		local character = player:Spawn()
		fake.Physics:Set(character, { X = 0, Y = 3, Z = i * 10 })
		if opts.Combat then
			Fakes.instance("Tool", "Rifle", character)
		end
		players[i] = player
	end

	local world = {
		framework = framework,
		fake = fake,
		behavioral = behavioral,
		combat = combat,
		players = players,
	}

	if opts.Combat then
		local dummy = fake.Players:Join(Fakes.player(100, "Dummy"))
		local dummyCharacter = dummy:Spawn()
		fake.Physics:Set(dummyCharacter, { X = 50, Y = 3, Z = 0 })
		local torso = Fakes.instance("Part", "UpperTorso", dummyCharacter)
		local head = Fakes.instance("Part", "Head", dummyCharacter)
		fake.Physics:SetTarget(torso, { X = 50, Y = 3, Z = 0, Model = dummyCharacter, Player = dummy })
		fake.Physics:SetTarget(head, { X = 50, Y = 4.5, Z = 0, Model = dummyCharacter, Player = dummy, IsHead = true })
		world.dummy = dummy

		-- One rifle shot from player i: "miss", "body" or "head".
		function world.shoot(i: number, outcome: string)
			local claim = { Origin = Fakes.vector3(0, 4.5, i * 10) }
			if outcome == "body" then
				claim.Target = torso
				claim.HitPosition = Fakes.vector3(50, 3, 0)
			elseif outcome == "head" then
				claim.Target = head
				claim.HitPosition = Fakes.vector3(50, 4.5, 0)
			end
			return combat:ValidateAttack(players[i], "Rifle", claim)
		end
	end

	function world.advance(seconds: number)
		fake.Clock.Advance(seconds)
		framework:Step()
	end

	-- Behavioural evidence kinds for player i (or a player object), as a set.
	function world.kinds(target)
		local player = if type(target) == "number" then players[target] else target
		local kinds = {}
		for _, record in framework:GetEvidence(player) do
			if record.Category == "Behavioral" then
				kinds[record.Kind] = record
			end
		end
		return kinds
	end

	-- Indices of players with any behavioural evidence.
	function world.flagged(): { number }
		local list = {}
		for i, player in players do
			if next(world.kinds(player)) ~= nil then
				table.insert(list, i)
			end
		end
		return list
	end

	return world
end

return Harness
