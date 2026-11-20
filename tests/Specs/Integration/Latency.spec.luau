--[[
	Phase 8 latency sweep: honest populations at increasing ping, with jittery delivery
	(stalls at >= 0.25 s), lag spikes, jumps, combat against moving targets, economy and
	remotes. Up to the compensation limit (Movement/Combat MaxPingCompensationSeconds 0.5)
	there must be no evidence at all; beyond it, no enforcement.
]]

local Simulation = require(script.Parent.Parent.Simulation)

return function(t)
	local expect = t.expect

	local function honestRun(seed, ping)
		local sim = Simulation.new({ Seed = seed, Ping = ping, Config = { Enforcement = { ShadowMode = true } } })
		for _ = 1, 15 do
			sim.add("Honest")
		end
		sim.run(180)
		return sim, sim.honestReport()
	end

	local function describe(report)
		local kinds = {}
		for kind, count in report.Kinds do
			table.insert(kinds, `{kind} x{count}`)
		end
		return table.concat(kinds, ", ")
	end

	t.describe("Latency", function()
		for _, case in { { 0.02, 0.08 }, { 0.15, 0.25 }, { 0.3, 0.4 }, { 0.45, 0.5 } } do
			t.it(`no evidence for honest players at {case[1]}-{case[2]} s ping`, function()
				local _, report = honestRun(21, case)
				if report.WithEvidence > 0 then
					error({ __testFailure = true, message = "honest evidence: " .. describe(report) }, 0)
				end
			end)
		end

		t.it("beyond the compensation limit (0.6-0.9 s ping): no enforcement and no restriction", function()
			local sim, report = honestRun(22, { 0.6, 0.9 })
			expect(report.Restricted).toBe(0)
			expect(report.Kicked).toBe(0)
			for _, agent in sim.agents do
				expect(#sim.framework:GetAuditLog({ UserId = agent.id, Type = "ShadowAction" })).toBe(0)
			end
		end)
	end)
end
