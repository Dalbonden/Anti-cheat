local ACF = game:GetService("ServerScriptService").ACF
local BehavioralDetectors = require(ACF.Detection.Behavioral.BehavioralDetectors)

local SIGNALS = {
	BucketSeconds = 10,
	SelfAlpha = 0.2,
	MinPlayerBuckets = 3,
	ActiveWithinBuckets = 6,
	MinContributors = 4,
	MinRelativeStdDev = 0.1,
	ZClamp = 3,
	CusumK = 0.5,
	CusumH = 6,
	MinRatio = 2,
	HardLimitTolerance = 0.1,
}

local ACCURACY = {
	CheckAccuracy = true,
	CheckHeadshots = true,
	ConfidenceZ = 3.09,
	MinShots = 40,
	AccuracyMargin = 0.35,
	AccuracyFloor = 0.9,
	AccuracyFloorWithoutBaseline = 0.95,
	MinPopulationShots = 200,
	MinHits = 20,
	HeadshotMargin = 0.4,
	HeadshotFloor = 0.75,
	HeadshotFloorWithoutBaseline = 0.9,
	MinPopulationHits = 100,
}

local ACTIONS = {
	CheckTiming = true,
	WindowSize = 30,
	MaxCV = 0.02,
	MinMeanIntervalSeconds = 0.1,
	MaxMeanIntervalSeconds = 10,
	MaxGapSeconds = 30,
	InvalidHalfLifeSeconds = 60,
	MinInvalid = 20,
	MaxInvalidRatio = 0.8,
	InvalidConfidenceZ = 2.33,
}

local COINS = { Name = "Coins", MaxPerSecond = nil, Baseline = nil, MinStdDev = 0, Statistical = true }

-- A player whose EWMA has been fed `rates` (one per bucket, starting at t = 10).
local function playerWith(rates)
	local p = BehavioralDetectors.newSignalPlayer()
	BehavioralDetectors.closeBucket(p, 0, SIGNALS) -- discards the partial first bucket
	for i, rate in rates do
		BehavioralDetectors.recordSignal(p, rate * 10)
		BehavioralDetectors.closeBucket(p, i * 10, SIGNALS)
	end
	return p
end

local function kinds(violations)
	local list = {}
	for _, v in violations do
		table.insert(list, v.Kind)
	end
	return list
end

return function(t)
	local expect = t.expect

	t.describe("BehavioralDetectors: signals", function()
		t.it("discards the first partial bucket and counts empty buckets afterwards", function()
			local p = BehavioralDetectors.newSignalPlayer()
			BehavioralDetectors.recordSignal(p, 500)
			expect(BehavioralDetectors.closeBucket(p, 3, SIGNALS)).toBeNil()
			BehavioralDetectors.recordSignal(p, 50)
			expect(BehavioralDetectors.closeBucket(p, 13, SIGNALS)).toBe(5)
			expect(BehavioralDetectors.closeBucket(p, 23, SIGNALS)).toBe(0)
			expect(p.ActiveBuckets).toBe(1)
			expect(p.BucketsSinceActive).toBe(1)
			expect(p.Self.Count).toBe(2)
		end)

		t.it("keeps accumulating when a bucket is shorter than half the bucket length", function()
			local p = BehavioralDetectors.newSignalPlayer()
			BehavioralDetectors.closeBucket(p, 0, SIGNALS)
			BehavioralDetectors.recordSignal(p, 40)
			expect(BehavioralDetectors.closeBucket(p, 4, SIGNALS)).toBeNil()
			expect(BehavioralDetectors.closeBucket(p, 8, SIGNALS)).toBe(5)
		end)

		t.it("lumpy and steady earners at the same average have the same mean", function()
			local steady = playerWith(table.create(40, 5))
			local lumps = {}
			for i = 1, 40 do
				lumps[i] = if i % 2 == 0 then 10 else 0
			end
			local lumpy = playerWith(lumps)
			expect(math.abs(steady.Self.Mean - lumpy.Self.Mean)).toBeLessThan(1.2)
		end)

		t.it("population baseline is the median player and ignores one extreme player", function()
			local players = {
				playerWith({ 5, 5, 5, 5 }),
				playerWith({ 6, 6, 6, 6 }),
				playerWith({ 4, 4, 4, 4 }),
				playerWith({ 5, 5, 5, 5 }),
				playerWith({ 500, 500, 500, 500 }),
			}
			local baseline = BehavioralDetectors.populationBaseline(players, SIGNALS, 0)
			expect(baseline ~= nil).toBe(true)
			expect(baseline.Mean).toBe(5)
			expect(baseline.Players).toBe(5)
			expect(baseline.Scale < 2).toBe(true)
		end)

		t.it("no population baseline below MinContributors or for inactive players", function()
			local few = { playerWith({ 5, 5, 5 }), playerWith({ 5, 5, 5 }), playerWith({ 5, 5, 5 }) }
			expect(BehavioralDetectors.populationBaseline(few, SIGNALS, 0)).toBeNil()
			local idle = playerWith({ 5, 0, 0, 0, 0, 0, 0 })
			expect(BehavioralDetectors.recentlyActive(idle, SIGNALS)).toBe(false)
			table.insert(few, idle)
			expect(BehavioralDetectors.populationBaseline(few, SIGNALS, 0)).toBeNil()
		end)

		t.it("a single extreme bucket cannot raise a SignalAnomaly", function()
			local p = playerWith({ 5, 5, 5 })
			local baseline = { Mean = 5, Scale = 1, Players = 5, Source = "Population" }
			local violations = BehavioralDetectors.evaluateSignal(COINS, p, 1e6, baseline, SIGNALS)
			expect(#violations).toBe(0)
		end)

		t.it("a sustained excess raises SignalAnomaly with an explanation", function()
			local p = playerWith({ 5, 5, 5 })
			local baseline = { Mean = 5, Scale = 1, Players = 5, Source = "Population" }
			local found = nil
			for i = 1, 6 do
				BehavioralDetectors.recordSignal(p, 500)
				local rate = BehavioralDetectors.closeBucket(p, 30 + i * 10, SIGNALS)
				local violations = BehavioralDetectors.evaluateSignal(COINS, p, rate, baseline, SIGNALS)
				if #violations > 0 then
					found = violations[1]
					expect(i >= 3).toBe(true)
					break
				end
			end
			expect(found ~= nil).toBe(true)
			expect(found.Kind).toBe("SignalAnomaly")
			expect(found.Details.Signal).toBe("Coins")
			expect(found.Details.Ratio > 2).toBe(true)
			expect(found.Details.BaselineSource).toBe("Population")
		end)

		t.it("a statistically unusual but practically small excess is not reported (MinRatio)", function()
			local p = playerWith({ 5, 5, 5 })
			-- Tiny scale makes every bucket z = 3, but 7/5 is below MinRatio 2.
			local baseline = { Mean = 5, Scale = 0.01, Players = 5, Source = "Population" }
			for i = 1, 20 do
				BehavioralDetectors.recordSignal(p, 70)
				local rate = BehavioralDetectors.closeBucket(p, 30 + i * 10, SIGNALS)
				expect(#BehavioralDetectors.evaluateSignal(COINS, p, rate, baseline, SIGNALS)).toBe(0)
			end
		end)

		t.it("hard limit reports with weight scaled by the excess, and Statistical = false skips CUSUM", function()
			local definition = { Name = "Gems", MaxPerSecond = 2, Baseline = nil, MinStdDev = 0, Statistical = false }
			local p = playerWith({ 1 })
			expect(#BehavioralDetectors.evaluateSignal(definition, p, 2.1, nil, SIGNALS)).toBe(0) -- within tolerance
			local v = BehavioralDetectors.evaluateSignal(definition, p, 3, nil, SIGNALS)
			expect(kinds(v)).toEqual({ "SignalRateLimit" })
			expect(v[1].Weight).toBe(1)
			expect(BehavioralDetectors.evaluateSignal(definition, p, 100, nil, SIGNALS)[1].Weight).toBe(2)
			local baseline = { Mean = 0.1, Scale = 0.01, Players = 5, Source = "Population" }
			for _ = 1, 10 do
				expect(kinds(BehavioralDetectors.evaluateSignal(definition, p, 1.5, baseline, SIGNALS))).toEqual({})
			end
		end)
	end)

	t.describe("BehavioralDetectors: accuracy", function()
		local function counts(shots, hits, heads)
			return { Shots = shots, Hits = hits, Heads = heads, Updated = 0 }
		end

		t.it("needs MinShots before judging accuracy", function()
			local v = BehavioralDetectors.evaluateAccuracy("Rifle", counts(39, 39, 0), counts(1000, 300, 30), ACCURACY)
			expect(#v).toBe(0)
		end)

		t.it("flags near-perfect accuracy over many shots against the server's ratio", function()
			local player = counts(300, 295, 0)
			local population = counts(300 + 2000, 295 + 700, 0)
			local v = BehavioralDetectors.evaluateAccuracy("Rifle", player, population, ACCURACY)
			expect(kinds(v)).toEqual({ "AccuracyAnomaly" })
			expect(v[1].Details.Basis).toBe("Population")
			expect(v[1].Details.PopulationRatio).toBe(0.35) -- the player's own shots are excluded
		end)

		t.it("does not flag a strong player (80% over 500 shots)", function()
			local v = BehavioralDetectors.evaluateAccuracy("Rifle", counts(500, 400, 0), counts(3000, 1300, 0), ACCURACY)
			expect(#v).toBe(0)
		end)

		t.it("does not flag a short perfect streak", function()
			local v = BehavioralDetectors.evaluateAccuracy("Rifle", counts(60, 60, 0), counts(3000, 1100, 0), ACCURACY)
			expect(#v).toBe(0)
		end)

		t.it("uses the absolute floor without enough population shots", function()
			local v = BehavioralDetectors.evaluateAccuracy("Rifle", counts(300, 280, 0), counts(350, 290, 0), ACCURACY)
			expect(#v).toBe(0) -- 93% is below the 95% no-baseline floor
			local v2 = BehavioralDetectors.evaluateAccuracy("Rifle", counts(400, 400, 0), counts(450, 410, 0), ACCURACY)
			expect(kinds(v2)).toEqual({ "AccuracyAnomaly" })
			expect(v2[1].Details.Basis).toBe("Absolute")
		end)

		t.it("flags headshot ratios far above the server's", function()
			local v = BehavioralDetectors.evaluateAccuracy("Rifle", counts(200, 120, 115), counts(2200, 920, 235), ACCURACY)
			expect(kinds(v)).toEqual({ "HeadshotAnomaly" })
			expect(v[1].Details.Headshots).toBe(115)
		end)

		t.it("headshot-heavy but plausible play is not flagged (55% of 200 hits)", function()
			local v = BehavioralDetectors.evaluateAccuracy("Rifle", counts(400, 200, 110), counts(3000, 1200, 300), ACCURACY)
			expect(#v).toBe(0)
		end)

		t.it("ageing halves counts per half-life", function()
			local c = counts(100, 50, 10)
			BehavioralDetectors.ageCounts(c, 600, 600)
			expect(c.Shots).toBeCloseTo(50, 6)
			expect(c.Hits).toBeCloseTo(25, 6)
			expect(c.Updated).toBe(600)
		end)
	end)

	t.describe("BehavioralDetectors: actions", function()
		local function run(intervals, valid)
			local state = BehavioralDetectors.newActionState(0)
			local now = 0
			local found = {}
			BehavioralDetectors.recordAction(state, "Click", valid ~= false, now, ACTIONS)
			for _, interval in intervals do
				now += interval
				local v = BehavioralDetectors.recordAction(state, "Click", valid ~= false, now, ACTIONS)
				if v then
					table.insert(found, v)
				end
			end
			return found, state
		end

		t.it("flags machine-regular timing once per full window", function()
			local intervals = {}
			for i = 1, 60 do
				intervals[i] = 0.5 + (if i % 2 == 0 then 0.002 else -0.002)
			end
			local found = run(intervals)
			expect(#found).toBe(2)
			expect(found[1].Kind).toBe("RegularTiming")
			expect(found[1].Details.CV < 0.02).toBe(true)
			expect(found[1].Details.Samples).toBe(30)
		end)

		t.it("does not flag rhythmic human timing (CV 5%)", function()
			local intervals = {}
			for i = 1, 90 do
				intervals[i] = 0.5 * (1 + 0.05 * math.sin(i * 1.7) * 1.4)
			end
			local found = run(intervals)
			expect(#found).toBe(0)
		end)

		t.it("a long gap starts a new run", function()
			local intervals = table.create(20, 1)
			table.insert(intervals, 60)
			for _ = 1, 20 do
				table.insert(intervals, 1)
			end
			local found = run(intervals)
			expect(#found).toBe(0)
		end)

		t.it("ignores very fast and very slow regular actions outside the configured range", function()
			expect(#run(table.create(60, 0.05))).toBe(0) -- 20 per second: below MinMeanInterval
			expect(#run(table.create(60, 20))).toBe(0) -- every 20 s: above MaxMeanInterval
		end)

		t.it("invalid ratio needs volume and a high lower bound", function()
			local _, state = run(table.create(10, 1), false) -- 11 invalid
			expect(BehavioralDetectors.evaluateInvalid(state, "Buy", 10, ACTIONS)).toBeNil()
			local _, flood = run(table.create(40, 0.5), false)
			local v = BehavioralDetectors.evaluateInvalid(flood, "Buy", 20, ACTIONS)
			expect(v ~= nil).toBe(true)
			expect(v.Kind).toBe("RepeatedInvalidActions")
			-- Mostly valid traffic with some invalid actions is fine.
			local mixed = BehavioralDetectors.newActionState(0)
			for i = 1, 100 do
				BehavioralDetectors.recordAction(mixed, "Buy", i % 3 ~= 0, i * 0.3, ACTIONS)
			end
			expect(BehavioralDetectors.evaluateInvalid(mixed, "Buy", 30, ACTIONS)).toBeNil()
		end)
	end)
end
