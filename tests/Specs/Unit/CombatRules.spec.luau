local ACF = game:GetService("ServerScriptService").ACF
local CombatRules = require(ACF.Detection.Combat.CombatRules)

return function(t)
	local expect = t.expect

	t.describe("CombatRules", function()
		t.it("normalizes a hitscan definition with defaults", function()
			local def = CombatRules.normalize("Rifle", { Kind = "Hitscan", Damage = 25, FireRate = 10, MaxRange = 300 })
			expect(def.HeadshotMultiplier).toBe(1)
			expect(def.Burst).toBe(1)
			expect(def.RequireLineOfSight).toBe(true)
			expect(def.RequireTarget).toBe(false)
			expect(def.Ammo).toBeNil()
			expect(table.isfrozen(def)).toBe(true)
		end)

		t.it("rejects invalid definitions with precise messages", function()
			local cases = {
				{ { Kind = "Laser", MaxRange = 1 }, "Kind must be" },
				{ { Kind = "Hitscan", MaxRange = 100 }, "FireRate is required" },
				{ { Kind = "Hitscan", FireRate = 5 }, "MaxRange is required" },
				{ { Kind = "Projectile", FireRate = 1, MaxRange = 100 }, "ProjectileSpeed is required" },
				{ { Kind = "Hitscan", FireRate = 1, MaxRange = 100, ProjectileSpeed = 5 }, "only applies" },
				{ { Kind = "Hitscan", FireRate = 1, MaxRange = 100, Damage = -1 }, "Damage must be" },
				{ { Kind = "Hitscan", FireRate = 1, MaxRange = 100, Dmg = 5 }, "unknown field 'Dmg'" },
				{ { Kind = "Hitscan", FireRate = 1, MaxRange = 100, Ammo = { Magazine = 0 } }, "Magazine" },
				{ { Kind = "Hitscan", FireRate = 1, MaxRange = 100, Falloff = { Start = 50, End = 10, MinMultiplier = 0.5 } }, "Falloff" },
				{ { Kind = "Hitscan", FireRate = 0 / 0, MaxRange = 100 }, "FireRate must be" },
			}
			for _, case in cases do
				expect(function()
					CombatRules.normalize("W", case[1])
				end).toThrow(case[2])
			end
		end)

		t.it("computes falloff and headshot damage", function()
			local def = CombatRules.normalize("Rifle", {
				Kind = "Hitscan",
				Damage = 40,
				FireRate = 5,
				MaxRange = 500,
				HeadshotMultiplier = 2,
				Falloff = { Start = 100, End = 300, MinMultiplier = 0.5 },
			})
			expect(CombatRules.damage(def, 50, false)).toBe(40)
			expect(CombatRules.damage(def, 200, false)).toBeCloseTo(30, 1e-9)
			expect(CombatRules.damage(def, 400, false)).toBe(20)
			expect(CombatRules.damage(def, 50, true)).toBe(80)
		end)

		t.it("models projectile motion with gravity", function()
			local x, y, z = CombatRules.projectilePosition(0, 10, 0, 1, 0, 0, 100, 20, 0.5)
			expect(x).toBe(50)
			expect(y).toBeCloseTo(10 - 0.5 * 20 * 0.25, 1e-9)
			expect(z).toBe(0)
		end)

		t.it("reads only finite Vector3 claims", function()
			local Fakes = require(game:GetService("ServerStorage").ACFTests.Fakes)
			expect((CombatRules.vector(Fakes.vector3(1, 2, 3)))).toBe(1)
			expect((CombatRules.vector(Fakes.vector3(0 / 0, 2, 3)))).toBeNil()
			expect((CombatRules.vector({ X = 1, Y = 2, Z = 3 }))).toBeNil()
		end)
	end)
end
