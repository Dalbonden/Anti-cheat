--[[
	Legitimate combat: every scenario must be accepted (or refused without blame) and must
	produce no Combat evidence. Covers max-rate fire, reload cycles, laggy shooters,
	moving targets, projectile travel, abilities, kill races and friendly-fire rules.
]]

local Harness = require(script.Parent.CombatHarness)
local Fakes = require(script.Parent.Parent.Fakes)

return function(t)
	local expect = t.expect

	local function expectClean(arena)
		local evidence = arena.combatEvidence()
		if #evidence > 0 then
			error({ __testFailure = true, message = "unexpected combat evidence: " .. table.concat(evidence, ", ") }, 0)
		end
	end

	t.describe("Legitimate combat", function()
		t.it("hits are authorized with server-computed damage", function()
			local a = Harness.arena({ Weapons = { Rifle = Harness.RIFLE } })
			local result = a.combat:ValidateAttack(a.shooter, "Rifle", a.claim())
			expect(result.Allowed).toBe(true)
			expect(result.Damage).toBe(25)
			expect(result.Target.Player).toBe(a.victim)
			a.advance(0.1)
			local headshot = a.combat:ValidateAttack(
				a.shooter,
				"Rifle",
				a.claim({ Target = a.head, HitPosition = Fakes.vector3(50, 4.5, 0) })
			)
			a.advance(0.1)
			expect(headshot.Allowed).toBe(true)
			expect(headshot.Damage).toBe(50)
			expect(headshot.Headshot).toBe(true)
			expectClean(a)
		end)

		t.it("firing a full magazine at the maximum fire rate, then reloading", function()
			local a = Harness.arena({ Weapons = { Rifle = Harness.RIFLE } })
			local accepted = 0
			for _ = 1, 30 do
				if a.combat:ValidateAttack(a.shooter, "Rifle", a.claim()).Allowed then
					accepted += 1
				end
				a.advance(0.1)
			end
			expect(accepted).toBe(30)
			expect((a.combat:GetAmmo(a.shooter, "Rifle"))).toBe(0)
			expect((a.combat:Reload(a.shooter, "Rifle"))).toBe(true)
			a.advance(2)
			local magazine, reserve = a.combat:GetAmmo(a.shooter, "Rifle")
			expect(magazine).toBe(30)
			expect(reserve).toBe(60)
			expect(a.combat:ValidateAttack(a.shooter, "Rifle", a.claim()).Allowed).toBe(true)
			expectClean(a)
		end)

		t.it("a laggy client whose shots arrive in small bunches", function()
			local a = Harness.arena({ Weapons = { Rifle = Harness.RIFLE } })
			-- Two shots delivered together, then a gap: average rate is still 10/s.
			for _ = 1, 10 do
				a.combat:ValidateAttack(a.shooter, "Rifle", a.claim())
				a.advance(0.09)
				a.combat:ValidateAttack(a.shooter, "Rifle", a.claim())
				a.advance(0.11)
			end
			expectClean(a)
		end)

		t.it("a shooter with high ping hitting a moving target", function()
			local a = Harness.arena({ Weapons = { Rifle = Harness.RIFLE } })
			a.fake.Physics:Set(a.shooterCharacter, { Ping = 0.4 })
			for i = 1, 20 do
				-- The client saw the target ~0.4 s ago: claimed hit lags the server position.
				local claimedX = 50 + (i - 1) * 3
				a.moveVictim(50 + i * 3 + 6)
				a.combat:ValidateAttack(a.shooter, "Rifle", a.claim({ HitPosition = Fakes.vector3(claimedX, 3, 0) }))
				a.advance(0.15)
			end
			expectClean(a)
		end)

		t.it("a shooter moving while firing (origin follows the character)", function()
			local a = Harness.arena({ Weapons = { Rifle = Harness.RIFLE } })
			a.fake.Physics:Set(a.shooterCharacter, { Ping = 0.15 })
			for i = 1, 20 do
				local x = i * 16 * 0.15
				a.fake.Physics:Set(a.shooterCharacter, { X = x })
				-- Client origin is where it was ~ping ago.
				a.combat:ValidateAttack(a.shooter, "Rifle", a.claim({ Origin = Fakes.vector3(x - 2.4, 4.5, 0) }))
				a.advance(0.15)
			end
			expectClean(a)
		end)

		t.it("kill race: shooting a target that just died is refused without blame", function()
			local a = Harness.arena({ Weapons = { Rifle = Harness.RIFLE } })
			a.fake.Physics:SetTarget(a.torso, { X = 50, Y = 3, Z = 0, Model = a.victimCharacter, Player = a.victim, Alive = false })
			for _ = 1, 20 do
				local result = a.combat:ValidateAttack(a.shooter, "Rifle", a.claim())
				expect(result.Allowed).toBe(false)
				expect(result.Reason).toBe("TargetDead")
				expect(result.ShotAccepted).toBe(true)
				a.advance(0.1)
			end
			expectClean(a)
		end)

		t.it("missed shots (no target) are fine and still consume ammo", function()
			local a = Harness.arena({ Weapons = { Rifle = Harness.RIFLE } })
			for _ = 1, 5 do
				local result = a.combat:ValidateAttack(a.shooter, "Rifle", a.claim({ Target = Fakes.NONE, HitPosition = Fakes.NONE }))
				expect(result.Allowed).toBe(true)
				expect(result.Damage).toBe(0)
				a.advance(0.1)
			end
			expect((a.combat:GetAmmo(a.shooter, "Rifle"))).toBe(25)
			expectClean(a)
		end)

		t.it("melee within reach", function()
			local a = Harness.arena({ Weapons = { Sword = Harness.SWORD }, VictimDistance = 5 })
			for _ = 1, 10 do
				local result = a.combat:ValidateAttack(a.shooter, "Sword", { Target = a.torso })
				expect(result.Allowed).toBe(true)
				expect(result.Damage).toBe(30)
				a.advance(0.5)
			end
			expectClean(a)
		end)

		t.it("projectile: fire, travel time, impact", function()
			local a = Harness.arena({ Weapons = { Rocket = Harness.ROCKET }, VictimDistance = 100 })
			for shot = 1, 5 do
				local id = "rocket-" .. shot
				local fired = a.combat:FireProjectile(a.shooter, "Rocket", {
					Origin = Fakes.vector3(0, 3, 0),
					Direction = Fakes.vector3(1, 0, 0),
					ShotId = id,
				})
				expect(fired.Allowed).toBe(true)
				a.advance(1.0) -- 100 studs at 100 studs/s
				local hit = a.combat:ValidateProjectileHit(a.shooter, id, { Target = a.torso, HitPosition = Fakes.vector3(100, 3, 0) })
				expect(hit.Allowed).toBe(true)
				expect(hit.Damage).toBe(80)
				a.advance(0.1)
			end
			expectClean(a)
		end)

		t.it("lobbed projectile with gravity", function()
			local weapons = {
				Grenade = {
					Kind = "Projectile",
					Damage = 60,
					FireRate = 1,
					MaxRange = 200,
					ProjectileSpeed = 50,
					ProjectileGravity = 50,
				},
			}
			local a = Harness.arena({ Weapons = weapons, VictimDistance = 50 })
			-- 45 degree throw from (0,3,0): direction (0.7071, 0.7071, 0).
			a.combat:FireProjectile(a.shooter, "Grenade", {
				Origin = Fakes.vector3(0, 3, 0),
				Direction = Fakes.vector3(1, 1, 0),
				ShotId = "g1",
			})
			-- After t seconds: x = 35.36 t, y = 3 + 35.36 t - 25 t^2. At x = 50, t = 1.414.
			local tFlight = 50 / (50 * math.sqrt(0.5))
			a.advance(tFlight)
			local y = 3 + 50 * math.sqrt(0.5) * tFlight - 25 * tFlight * tFlight
			a.fake.Physics:SetTarget(a.torso, { X = 50, Y = y, Z = 0, Model = a.victimCharacter, Player = a.victim })
			local hit = a.combat:ValidateProjectileHit(a.shooter, "g1", { Target = a.torso, HitPosition = Fakes.vector3(50, y, 0) })
			expect(hit.Allowed).toBe(true)
			expectClean(a)
		end)

		t.it("piercing projectile hits two targets", function()
			local weapons = {
				Spear = { Kind = "Projectile", Damage = 30, FireRate = 1, MaxRange = 200, ProjectileSpeed = 200, Pierce = 1 },
			}
			local a = Harness.arena({ Weapons = weapons, VictimDistance = 40 })
			local other = Fakes.instance("Part", "Torso", Fakes.instance("Model", "Npc"))
			a.fake.Physics:SetTarget(other, { X = 60, Y = 3, Z = 0, Model = other.Parent })
			a.combat:FireProjectile(a.shooter, "Spear", { Origin = Fakes.vector3(0, 3, 0), Direction = Fakes.vector3(1, 0, 0), ShotId = "s1" })
			a.advance(0.2)
			expect(a.combat:ValidateProjectileHit(a.shooter, "s1", { Target = a.torso }).Allowed).toBe(true)
			a.advance(0.1)
			expect(a.combat:ValidateProjectileHit(a.shooter, "s1", { Target = other }).Allowed).toBe(true)
			expectClean(a)
		end)

		t.it("ability used exactly on cooldown, including an AoE without a target", function()
			local a = Harness.arena({ Weapons = { Fireball = Harness.FIREBALL } })
			for _ = 1, 4 do
				local result = a.combat:ValidateAttack(a.shooter, "Fireball", { HitPosition = Fakes.vector3(40, 3, 0) })
				expect(result.Allowed).toBe(true)
				a.advance(4.95) -- within the cooldown tolerance
			end
			expectClean(a)
		end)

		t.it("team rules: friendly fire is refused without heavy blame", function()
			local a = Harness.arena({ Weapons = { Rifle = Harness.RIFLE } })
			a.combat:SetProvider("CanDamage", function(_, target)
				return target.Player ~= a.victim
			end)
			for _ = 1, 4 do
				local result = a.combat:ValidateAttack(a.shooter, "Rifle", a.claim())
				expect(result.Reason).toBe("FriendlyFire")
				a.advance(0.1)
			end
			expectClean(a)
		end)

		t.it("custom damage via DamageCalculator", function()
			local a = Harness.arena({ Weapons = { Rifle = Harness.RIFLE } })
			a.combat:SetProvider("DamageCalculator", function(info)
				return info.BaseDamage * 0.5
			end)
			expect(a.combat:ValidateAttack(a.shooter, "Rifle", a.claim()).Damage).toBe(12.5)
		end)

		t.it("game-managed ammo via SetAmmo", function()
			local a = Harness.arena({ Weapons = { Rifle = Harness.RIFLE } })
			a.combat:SetAmmo(a.shooter, "Rifle", 1, 0)
			expect(a.combat:ValidateAttack(a.shooter, "Rifle", a.claim()).Allowed).toBe(true)
			a.advance(0.1)
			local empty = a.combat:ValidateAttack(a.shooter, "Rifle", a.claim())
			expect(empty.Reason).toBe("NoAmmo")
			expect((a.combat:Reload(a.shooter, "Rifle"))).toBe(false)
		end)

		t.it("shooting world parts and NPCs", function()
			local a = Harness.arena({ Weapons = { Rifle = Harness.RIFLE } })
			local crate = Fakes.instance("Part", "Crate")
			a.fake.Physics:SetTarget(crate, { X = 30, Y = 1, Z = 0 })
			local result = a.combat:ValidateAttack(a.shooter, "Rifle", a.claim({ Target = crate, HitPosition = Fakes.vector3(30, 1, 0) }))
			expect(result.Allowed).toBe(true)
			expect(result.Target.Model).toBeNil()
			expectClean(a)
		end)
	end)
end
