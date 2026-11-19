local ACF = game:GetService("ServerScriptService").ACF
local Statistics = require(ACF.Intelligence.Statistics)

return function(t)
	local expect = t.expect

	t.describe("Statistics", function()
		t.it("EWMA starts at the first value and converges to a constant input", function()
			local e = Statistics.newEwma()
			Statistics.updateEwma(e, 10, 0.2)
			expect(e.Mean).toBe(10)
			expect(e.Variance).toBe(0)
			for _ = 1, 200 do
				Statistics.updateEwma(e, 20, 0.2)
			end
			expect(e.Mean).toBeCloseTo(20, 4)
			expect(Statistics.stdDev(e)).toBeLessThan(0.01)
			expect(e.Count).toBe(201)
		end)

		t.it("EWMA variance approximates the variance of an alternating input", function()
			local e = Statistics.newEwma()
			for i = 1, 2000 do
				Statistics.updateEwma(e, if i % 2 == 0 then 0 else 10, 0.05)
			end
			expect(math.abs(e.Mean - 5)).toBeLessThan(0.5)
			-- Population variance of {0, 10} is 25; the EW estimate is close to it.
			expect(math.abs(e.Variance - 25)).toBeLessThan(3)
		end)

		t.it("CUSUM ignores values at or below the allowance", function()
			local c = Statistics.newCusum()
			for _ = 1, 1000 do
				local alarm = Statistics.cusumStep(c, 0.5, 0.5, 6)
				expect(alarm).toBe(false)
			end
			expect(c.S).toBe(0)
		end)

		t.it("CUSUM with clamped z needs several steps to alarm, then resets", function()
			local c = Statistics.newCusum()
			local z = Statistics.zScore(1e9, 1, 1, 0, 0, 3) -- clamped to 3
			expect(z).toBe(3)
			expect((Statistics.cusumStep(c, z, 0.5, 6))).toBe(false) -- 2.5
			expect((Statistics.cusumStep(c, z, 0.5, 6))).toBe(false) -- 5.0
			local alarm, statistic, steps = Statistics.cusumStep(c, z, 0.5, 6) -- 7.5
			expect(alarm).toBe(true)
			expect(statistic).toBeCloseTo(7.5, 6)
			expect(steps).toBe(3)
			expect(c.S).toBe(0)
		end)

		t.it("CUSUM drifts back to zero when values return to normal", function()
			local c = Statistics.newCusum()
			Statistics.cusumStep(c, 3, 0.5, 6)
			Statistics.cusumStep(c, 3, 0.5, 6)
			Statistics.cusumStep(c, -3, 0.5, 6)
			Statistics.cusumStep(c, -3, 0.5, 6)
			expect(c.S).toBe(0)
			expect(c.Steps).toBe(0)
		end)

		t.it("z-score floors the scale so near-zero variance cannot explode", function()
			expect(Statistics.zScore(10.1, 10, 0, 0, 0.1, 3)).toBeCloseTo(0.1, 6) -- scale = 1
			expect(Statistics.zScore(12, 10, 0.001, 2, 0, 10)).toBeCloseTo(1, 6)
			expect(Statistics.zScore(5, 0, 0, 0, 0, 3)).toBe(0) -- no scale at all
			expect(Statistics.zScore(-100, 0, 1, 0, 0, 3)).toBe(-3)
		end)

		t.it("Wilson lower bound reflects sample size", function()
			-- 10/10 is weak evidence; 300/300 is strong.
			expect(Statistics.wilsonLower(10, 10, 3.09)).toBeLessThan(0.55)
			expect(Statistics.wilsonLower(300, 300, 3.09)).toBeGreaterThan(0.96)
			-- A known value: 50/100 at z = 1.96 is about 0.4038.
			expect(Statistics.wilsonLower(50, 100, 1.96)).toBeCloseTo(0.4038, 3)
			expect(Statistics.wilsonLower(0, 0, 3)).toBe(0)
			expect(Statistics.wilsonLower(0, 50, 3)).toBe(0)
		end)

		t.it("decay factor halves per half-life and never grows", function()
			expect(Statistics.decayFactor(10, 10)).toBeCloseTo(0.5, 9)
			expect(Statistics.decayFactor(30, 10)).toBeCloseTo(0.125, 9)
			expect(Statistics.decayFactor(-5, 10)).toBe(1)
		end)

		t.it("mean and sample standard deviation", function()
			local mean, std = Statistics.meanStd({ 2, 4, 4, 4, 5, 5, 7, 9 })
			expect(mean).toBe(5)
			expect(std).toBeCloseTo(2.138, 3)
			expect(select(2, Statistics.meanStd({ 3 }))).toBe(0)
			expect((Statistics.meanStd({}))).toBe(0)
		end)
	end)
end
