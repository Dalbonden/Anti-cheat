--[[
	Phase 8 population run (short version of tests/lune/evaluate.luau): honest players and
	one of each cheat in one server, full stack, enforcement in shadow mode.

	Honest players must produce no evidence, never leave the Normal band and never be the
	subject of an enforcement decision. Every cheat must be caught.
]]

local Simulation = require(script.Parent.Parent.Simulation)

return function(t)
	local expect = t.expect

	t.describe("Population", function()
		t.it("15 honest players and 9 cheaters for 4 minutes: every cheat caught, no honest evidence", function()
			local sim = Simulation.new({ Seed = 11, Config = { Enforcement = { ShadowMode = true } } })
			for _ = 1, 15 do
				sim.add("Honest")
			end
			local cheaters = {}
			for _, cheat in Simulation.CHEATS do
				cheaters[cheat] = sim.add(cheat, 30)
			end
			sim.run(240)

			local honest = sim.honestReport()
			local kinds = {}
			for kind, count in honest.Kinds do
				table.insert(kinds, `{kind} x{count}`)
			end
			if honest.WithEvidence > 0 then
				error({ __testFailure = true, message = "honest evidence: " .. table.concat(kinds, ", ") }, 0)
			end
			expect(honest.MaxBand).toBe("Normal")
			for _, agent in sim.agents do
				if agent.role == "Honest" then
					expect(#sim.framework:GetAuditLog({ UserId = agent.id, Type = "ShadowAction" })).toBe(0)
					expect(#sim.framework:GetAuditLog({ UserId = agent.id, Type = "Rejected" })).toBe(0)
				end
			end

			local missed = {}
			for cheat, agent in cheaters do
				if agent.firstEvidence == nil then
					table.insert(missed, cheat)
				end
			end
			table.sort(missed)
			expect(missed).toEqual({})
		end)

		t.it("live enforcement neutralises hard-evidence cheaters and never touches honest players", function()
			-- Each cheater must end up removed, or held at Correction or above with a staff
			-- case open. A flyer rubber-banded every second stops gaining airtime, so its
			-- risk can plateau below EnforcementReview: mitigated, and staff decide.
			local sim = Simulation.new({ Seed = 12 })
			for _ = 1, 15 do
				sim.add("Honest")
			end
			local cheaters = { sim.add("Fly", 20), sim.add("Teleport", 20), sim.add("Noclip", 20), sim.add("Speed", 20) }
			sim.run(240)
			for _, agent in cheaters do
				if not agent.kicked then
					local state = sim.framework:GetEnforcement(agent.id)
					if state.Level < 3 or state.OpenCase == nil then
						error({ __testFailure = true, message = `{agent.role} not neutralised: level {state.LevelName}, case {tostring(state.OpenCase)}` }, 0)
					end
				end
			end
			for _, agent in sim.agents do
				if agent.role == "Honest" then
					expect(agent.kicked).toBe(false)
					expect(sim.framework:GetEnforcement(agent.id).Level).toBe(0)
				end
			end
		end)
	end)
end
