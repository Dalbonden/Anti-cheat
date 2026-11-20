--[[
	Centralised risk inside the full framework. Probe modules report detections with
	chosen categories, severities and confidences; a real Movement run checks the
	end-to-end path.
]]

local ACF = game:GetService("ServerScriptService").ACF
local Framework = require(ACF.Core.Framework)
local Topics = require(ACF.Core.Topics)
local Fakes = require(script.Parent.Parent.Fakes)

local PROBES = {
	MoveProbe = "Movement",
	PhysProbe = "Physics", -- the "Physics" category is grouped with Movement by default
	AimProbe = "Combat",
	EcoProbe = "Economy",
	NetProbe = "Remote",
}

local function world(config, envOptions)
	local fake = Fakes.environment(envOptions)
	local framework = Framework.new(fake.Env)
	local probes = {}
	for name, category in PROBES do
		local probe = Fakes.module(name, { Category = category })
		framework:RegisterModule(probe)
		probes[name] = probe
	end
	framework:Initialize(config or {})
	framework:Start()
	local player = fake.Players:Join(Fakes.player(1, "Suspect"))
	local w = { framework = framework, fake = fake, player = player, probes = probes, changes = {} }
	framework:Subscribe(Topics.RiskChanged, function(payload)
		table.insert(w.changes, payload)
	end)
	function w.report(probe, kind, severity, confidence, target)
		return probes[probe].Context:Report(target or player, { Kind = kind, Severity = severity, Confidence = confidence })
	end
	function w.advance(seconds)
		local steps = math.max(1, math.ceil(seconds))
		for _ = 1, steps do
			fake.Clock.Advance(seconds / steps)
			framework:Step()
		end
	end
	function w.risk()
		return framework:GetRisk(player)
	end
	return w
end

return function(t)
	local expect = t.expect

	t.describe("Risk", function()
		t.it("one detection contributes severity x confidence", function()
			local w = world()
			w.report("MoveProbe", "TeleportDetected", 30, 0.8)
			local r = w.risk()
			expect(r.Risk).toBeCloseTo(24, 6)
			expect(r.Band).toBe("Increased")
			expect(r.Groups[1].Group).toBe("Movement")
			expect(r.Groups[1].Kinds[1].Kind).toBe("TeleportDetected")
		end)

		t.it("follows R = sum(w c exp(-lambda t)) across independent kinds", function()
			local w = world()
			local lambda = math.log(2) / 600
			w.report("MoveProbe", "TeleportDetected", 30, 1)
			w.advance(200)
			w.report("AimProbe", "CombatFireRate", 20, 0.5)
			w.advance(100)
			local expected = 30 * math.exp(-lambda * 300) + 20 * 0.5 * math.exp(-lambda * 100)
			expect(w.risk().Risk).toBeCloseTo(expected, 4)
		end)

		t.it("decays over time and publishes the lowered band", function()
			local w = world()
			w.report("MoveProbe", "TeleportDetected", 50, 1)
			expect(w.risk().Band).toBe("Restrict")
			w.advance(700)
			expect(w.risk().Band).toBe("Increased")
			local last = w.changes[#w.changes]
			expect(last.PreviousBand).toBe("Restrict")
			expect(last.Band).toBe("Increased")
			w.advance(3600)
			expect(w.risk().Band).toBe("Normal")
		end)

		t.it("suppresses duplicates: a burst of one kind counts once", function()
			local w = world()
			for _ = 1, 20 do
				w.report("NetProbe", "RemoteRateLimited", 20, 1)
			end
			local r = w.risk()
			expect(r.Risk).toBeCloseTo(20, 6)
			expect(r.Groups[1].Kinds[1].Suppressed).toBe(19)
			expect(w.framework:GetStatus().Risk.Suppressed).toBe(19)
		end)

		t.it("one kind repeating forever saturates at severity x confidence x RepeatCap", function()
			-- RepeatCap 3 (calibrated in Phase 8): sustained severe evidence escalates,
			-- low-severity evidence stays below EnforcementReview however long it lasts.
			-- Enforcement is off so the player is not removed part-way.
			local w = world({ Enforcement = { Mode = "Off" } })
			for _ = 1, 120 do -- 20 minutes of a report every 10 s
				w.report("MoveProbe", "Flight", 30, 0.9)
				w.report("NetProbe", "RemoteCooldownViolation", 10, 0.9)
				w.advance(10)
			end
			local r = w.risk()
			local movement, remote
			for _, group in r.Groups do
				if group.Group == "Movement" then
					movement = group.Score
				elseif group.Group == "Remote" then
					remote = group.Score
				end
			end
			expect(movement <= 81 + 1e-6).toBe(true)
			expect(movement > 78).toBe(true)
			expect(remote <= 27 + 1e-6).toBe(true)
			local single = world({ Enforcement = { Mode = "Off" } })
			for _ = 1, 120 do
				single.report("NetProbe", "RemoteCooldownViolation", 15, 0.9)
				single.advance(10)
			end
			-- 15 x 0.9 x 3 = 40.5 at most; decay between reports keeps it just below.
			expect(single.risk().Risk <= 40.5).toBe(true)
			expect(single.risk().Risk > 38).toBe(true)
		end)

		t.it("correlated kinds are not double-counted; independent groups add", function()
			local correlated = world()
			correlated.report("MoveProbe", "SpeedExceeded", 30, 1)
			correlated.report("PhysProbe", "VelocityMismatch", 30, 1)
			expect(correlated.risk().Risk).toBeCloseTo(37.5, 6) -- 30 + 0.25 x 30
			expect(#correlated.risk().Groups).toBe(1)

			local independent = world()
			independent.report("MoveProbe", "SpeedExceeded", 30, 1)
			independent.report("AimProbe", "CombatNoLineOfSight", 30, 1)
			expect(independent.risk().Risk).toBeCloseTo(60, 6)
			expect(independent.risk().Band).toBe("Investigation")
		end)

		t.it("several independent groups reach EnforcementReview with an explanation", function()
			local w = world()
			w.report("MoveProbe", "TeleportDetected", 30, 0.9)
			w.report("AimProbe", "CombatOutOfRange", 30, 0.9)
			w.report("EcoProbe", "SignalAnomaly", 20, 0.8)
			w.report("NetProbe", "RemoteInvalidArguments", 15, 0.8)
			local r = w.risk()
			expect(r.Band).toBe("EnforcementReview")
			expect(r.Confidence > 0.99).toBe(true)
			expect(string.find(r.Explanation, "TeleportDetected", 1, true) ~= nil).toBe(true)
			expect(string.find(r.Explanation, "CombatOutOfRange", 1, true) ~= nil).toBe(true)
			local bands = {}
			for _, change in w.changes do
				table.insert(bands, change.Band)
			end
			-- 27 -> 54 -> 70 -> 82
			expect(bands).toEqual({ "Increased", "Restrict", "Investigation", "EnforcementReview" })
			expect(w.changes[4].Session ~= nil).toBe(true)
		end)

		t.it("Groups configuration merges over the defaults", function()
			local w = world({ Risk = { Groups = { AimProbe = "Movement" } } })
			w.report("MoveProbe", "SpeedExceeded", 40, 1)
			w.report("AimProbe", "CombatFireRate", 40, 1)
			expect(w.risk().Risk).toBeCloseTo(50, 6)
			w.report("PhysProbe", "FlingDetected", 40, 1) -- default Physics -> Movement still applies
			expect(#w.risk().Groups).toBe(1)
		end)

		t.it("leaving and rejoining does not reset risk", function()
			local w = world()
			w.report("MoveProbe", "TeleportDetected", 50, 1)
			w.fake.Players:Leave(w.player)
			w.advance(10)
			w.fake.Players:Join(w.player)
			expect(w.risk().Risk > 49).toBe(true)
		end)

		t.it("history records detections and band changes; Reset clears and is recorded", function()
			local w = world()
			w.report("MoveProbe", "TeleportDetected", 50, 1)
			w.report("AimProbe", "CombatFireRate", 10, 1)
			local history = w.framework:GetRiskHistory(w.player)
			local types = {}
			for _, entry in history do
				table.insert(types, entry.Type)
			end
			-- 50 enters Restrict; +10 reaches Investigation.
			expect(types).toEqual({ "Band", "Detection", "Band", "Detection" })
			expect(history[2].Contribution).toBe(50)
			w.framework:ResetRisk(w.player, { Reason = "false positive, ticket 12" })
			expect(w.risk().Risk).toBe(0)
			local after = w.framework:GetRiskHistory(w.player)
			expect(after[#after].Type).toBe("Reset")
			expect(after[#after].Note).toBe("false positive, ticket 12")
			expect(w.changes[#w.changes].Band).toBe("Normal")
		end)

		t.it("per-user memory is bounded (keys and history)", function()
			local w = world()
			for i = 1, 150 do
				w.report("NetProbe", "Kind" .. i, 1, 0.5)
				w.advance(0.2) -- stay under the per-detector report rate limit
			end
			local r = w.risk()
			local kinds = 0
			for _, group in r.Groups do
				kinds += #group.Kinds
			end
			expect(kinds).toBe(64)
			expect(w.framework:GetStatus().Risk.Evicted).toBe(86)
			expect(#w.framework:GetRiskHistory(w.player) <= 50).toBe(true)
		end)

		t.it("departed users are forgotten once their risk has decayed", function()
			local w = world()
			w.report("MoveProbe", "TeleportDetected", 10, 1)
			w.fake.Players:Leave(w.player)
			expect(w.framework:GetStatus().Risk.Tracked).toBe(1)
			w.advance(7200)
			expect(w.framework:GetStatus().Risk.Tracked).toBe(0)
		end)

		t.it("invalid band order fails Initialize with a clear message", function()
			local fake = Fakes.environment()
			local framework = Framework.new(fake.Env)
			expect(function()
				framework:Initialize({ Risk = { Bands = { Restrict = 70 } } })
			end).toThrow("Risk.Bands.Investigation must be greater than Risk.Bands.Restrict")
			expect(framework:GetState()).toBe("Created")
		end)

		t.it("Risk.Enabled = false turns the engine off", function()
			local w = world({ Risk = { Enabled = false } })
			w.report("MoveProbe", "TeleportDetected", 50, 1)
			expect(w.framework:GetStatus().Risk).toBeNil()
			expect(function()
				w.framework:GetRisk(w.player)
			end).toThrow("risk assessment is disabled")
		end)

		t.it("end to end: a minute of hovering raises risk; walking does not", function()
			local fake = Fakes.environment()
			fake.Physics:AddFloor()
			local framework = Framework.new(fake.Env)
			framework:Initialize({})
			framework:Start()
			local cheater = fake.Players:Join(Fakes.player(1))
			local honest = fake.Players:Join(Fakes.player(2))
			local c1, c2 = cheater:Spawn(), honest:Spawn()
			fake.Physics:Set(c1, {})
			fake.Physics:Set(c2, {})
			for i = 1, 300 do -- one minute
				fake.Physics:Set(c1, { Y = 60, VY = 0 })
				fake.Physics:Set(c2, { X = i * 0.2 * 14 })
				fake.Clock.Advance(0.2)
				framework:Step()
			end
			local r = framework:GetRisk(cheater)
			expect(r.Band ~= "Normal").toBe(true)
			expect(string.find(r.Explanation, "Flight", 1, true) ~= nil).toBe(true)
			expect(framework:GetRisk(honest).Risk).toBe(0)
		end)
	end)
end
