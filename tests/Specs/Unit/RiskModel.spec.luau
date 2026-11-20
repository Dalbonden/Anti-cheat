local ACF = game:GetService("ServerScriptService").ACF
local RiskModel = require(ACF.Intelligence.RiskModel)

local BANDS = { Increased = 20, Restrict = 40, Investigation = 60, EnforcementReview = 80 }

local function key(group, score, confidence, detector, kind)
	return {
		Detector = detector or "D",
		Kind = kind or "K",
		Category = "Custom",
		Group = group,
		Score = score or 0,
		Updated = 0,
		Severity = 0,
		Confidence = confidence or 0,
		Count = 0,
		Suppressed = 0,
		LastAccepted = -math.huge,
	}
end

return function(t)
	local expect = t.expect

	t.describe("RiskModel", function()
		t.it("the first detection adds exactly severity x confidence", function()
			local k = key("G")
			expect(RiskModel.add(k, 30, 0.8, 2)).toBeCloseTo(24, 9)
			expect(k.Score).toBeCloseTo(24, 9)
			expect(k.Count).toBe(1)
		end)

		t.it("decays with lambda = ln 2 / half-life, i.e. exp(-lambda t)", function()
			local lambda = math.log(2) / 600
			expect(RiskModel.decay(50, 600, 600)).toBeCloseTo(25, 9)
			expect(RiskModel.decay(50, 250, 600)).toBeCloseTo(50 * math.exp(-lambda * 250), 9)
			expect(RiskModel.decay(50, -10, 600)).toBe(50)
		end)

		t.it("repeats of one kind saturate at severity x confidence x RepeatCap", function()
			local k = key("G")
			for _ = 1, 500 do
				RiskModel.add(k, 30, 0.9, 2)
			end
			expect(k.Score <= 54 + 1e-9).toBe(true)
			expect(k.Score > 53).toBe(true)
			-- Second detection adds half as much as the first (diminishing returns).
			local fresh = key("G")
			local first = RiskModel.add(fresh, 20, 1, 2)
			local second = RiskModel.add(fresh, 20, 1, 2)
			expect(first).toBe(20)
			expect(second).toBe(10)
		end)

		t.it("a zero-confidence or zero-severity detection adds nothing", function()
			local k = key("G")
			expect(RiskModel.add(k, 30, 0, 2)).toBe(0)
			expect(RiskModel.add(k, 0, 1, 2)).toBe(0)
			expect(k.Count).toBe(0)
		end)

		t.it("resolves groups by Detector.Kind, then Detector, then Category", function()
			local groups = { ["Behavioral.AccuracyAnomaly"] = "Aim", Physics = "Movement", Remote = "Net" }
			expect(RiskModel.groupFor("Behavioral", "AccuracyAnomaly", "Behavioral", groups)).toBe("Aim")
			expect(RiskModel.groupFor("Physics", "FlingDetected", "Physics", groups)).toBe("Movement")
			expect(RiskModel.groupFor("RemoteSecurity", "X", "Remote", groups)).toBe("Net")
			expect(RiskModel.groupFor("Combat", "CombatFireRate", "Combat", groups)).toBe("Combat")
		end)

		t.it("correlated keys: the strongest counts fully, the rest at SecondaryWeight", function()
			local groups = RiskModel.summarize({
				key("Movement", 30, 0.9, "Movement", "TeleportDetected"),
				key("Movement", 20, 0.5, "Physics", "VelocityMismatch"),
				key("Combat", 10, 0.7, "Combat", "CombatFireRate"),
			}, 0.25)
			expect(#groups).toBe(2)
			expect(groups[1].Group).toBe("Movement")
			expect(groups[1].Score).toBeCloseTo(35, 9)
			expect(groups[1].Confidence).toBe(0.9)
			expect(groups[1].Keys[1].Kind).toBe("TeleportDetected")
			expect(groups[2].Score).toBe(10)
		end)

		t.it("combines groups additively, capped at 100, with a noisy-OR confidence", function()
			local groups = RiskModel.summarize({ key("A", 30, 0.5), key("B", 40, 0.5) }, 0.25)
			local risk, confidence = RiskModel.combine(groups, 5)
			expect(risk).toBe(75)
			expect(confidence).toBeCloseTo(0.75, 9)
			local capped = RiskModel.combine(RiskModel.summarize({ key("A", 90), key("B", 90) }, 0.25), 0)
			expect(capped).toBe(100)
		end)

		t.it("bands follow the configured lower bounds", function()
			expect(RiskModel.band(0, BANDS)).toBe("Normal")
			expect(RiskModel.band(19.99, BANDS)).toBe("Normal")
			expect(RiskModel.band(20, BANDS)).toBe("Increased")
			expect(RiskModel.band(40, BANDS)).toBe("Restrict")
			expect(RiskModel.band(60, BANDS)).toBe("Investigation")
			expect(RiskModel.band(79.9, BANDS)).toBe("Investigation")
			expect(RiskModel.band(80, BANDS)).toBe("EnforcementReview")
			expect(RiskModel.band(100, BANDS)).toBe("EnforcementReview")
		end)

		t.it("explanations name each group and its strongest kinds", function()
			local k1 = key("Movement", 30, 0.9, "Movement", "TeleportDetected")
			k1.Count = 3
			k1.Severity = 30
			local groups = RiskModel.summarize({ k1 }, 0.25)
			local text = RiskModel.explain(42.5, "Restrict", groups, 10)
			expect(string.find(text, "Risk 42.5 (Restrict)", 1, true) ~= nil).toBe(true)
			expect(string.find(text, "TeleportDetected x3", 1, true) ~= nil).toBe(true)
			expect(string.find(text, "History 10", 1, true) ~= nil).toBe(true)
		end)
	end)
end
