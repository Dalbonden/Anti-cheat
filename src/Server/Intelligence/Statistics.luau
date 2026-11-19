--!strict
--[[
	Pure statistics used by behavioural detection. No Roblox APIs, no clocks: callers pass
	values and times in, so every function is deterministic and unit-tested.

	  Ewma          exponentially weighted mean and variance (West's incremental form).
	                Tracks a baseline that adapts slowly; alpha is the weight of each new
	                value (0.02 means about the last 50 values matter).
	  Cusum         one-sided (upper) cumulative-sum change detector on standardised
	                values:  S <- max(0, S + z - k);  alarm when S > h, then S resets.
	                k is the allowance (drift ignored per step) and h the decision interval.
	                With z clamped to zMax, an alarm needs at least ceil(h / (zMax - k))
	                steps: no single value can raise one.
	  zScore        standardises a value against a baseline, with a floor on the standard
	                deviation so a population with near-zero variance cannot turn a tiny
	                difference into a huge z.
	  wilsonLower   lower bound of the Wilson score interval for a proportion. A high
	                proportion observed over few trials gets a low bound, so it is the
	                sample-size guard for ratios (accuracy, headshots, invalid actions).
	  decayFactor   multiplier that ages exponentially decayed counts by `elapsed`.
	  meanStd       mean and sample standard deviation of a list.
]]

local Statistics = {}

export type Ewma = { Mean: number, Variance: number, Count: number }
export type Cusum = { S: number, Steps: number }

function Statistics.newEwma(): Ewma
	return { Mean = 0, Variance = 0, Count = 0 }
end

function Statistics.updateEwma(ewma: Ewma, value: number, alpha: number)
	if ewma.Count == 0 then
		ewma.Mean = value
		ewma.Variance = 0
	else
		local diff = value - ewma.Mean
		local increment = alpha * diff
		ewma.Mean += increment
		ewma.Variance = (1 - alpha) * (ewma.Variance + diff * increment)
	end
	ewma.Count += 1
end

function Statistics.stdDev(ewma: Ewma): number
	return math.sqrt(math.max(ewma.Variance, 0))
end

function Statistics.newCusum(): Cusum
	return { S = 0, Steps = 0 }
end

-- Adds one standardised value. Returns (alarm, statisticBeforeReset, stepsInRun).
function Statistics.cusumStep(cusum: Cusum, z: number, k: number, h: number): (boolean, number, number)
	cusum.S = math.max(0, cusum.S + z - k)
	if cusum.S > 0 then
		cusum.Steps += 1
	else
		cusum.Steps = 0
	end
	if cusum.S > h then
		local s, steps = cusum.S, cusum.Steps
		cusum.S = 0
		cusum.Steps = 0
		return true, s, steps
	end
	return false, cusum.S, cusum.Steps
end

-- (value - mean) / max(std, minStd, minRelative * |mean|), clamped to [-zMax, zMax].
function Statistics.zScore(value: number, mean: number, std: number, minStd: number, minRelative: number, zMax: number): number
	local scale = math.max(std, minStd, minRelative * math.abs(mean))
	if scale <= 0 then
		return 0
	end
	local z = (value - mean) / scale
	return math.clamp(z, -zMax, zMax)
end

-- Lower Wilson bound for `successes` out of `trials` (both may be fractional when the
-- counts are exponentially decayed). z = 3.09 is a one-sided 99.9% bound.
function Statistics.wilsonLower(successes: number, trials: number, z: number): number
	if trials <= 0 then
		return 0
	end
	local p = math.clamp(successes / trials, 0, 1)
	local z2 = z * z
	local denominator = 1 + z2 / trials
	local centre = p + z2 / (2 * trials)
	local margin = z * math.sqrt(p * (1 - p) / trials + z2 / (4 * trials * trials))
	return math.max(0, (centre - margin) / denominator)
end

function Statistics.decayFactor(elapsed: number, halfLife: number): number
	if elapsed <= 0 then
		return 1
	end
	return 0.5 ^ (elapsed / halfLife)
end

function Statistics.meanStd(values: { number }): (number, number)
	local n = #values
	if n == 0 then
		return 0, 0
	end
	local sum = 0
	for _, value in values do
		sum += value
	end
	local mean = sum / n
	if n == 1 then
		return mean, 0
	end
	local squares = 0
	for _, value in values do
		squares += (value - mean) ^ 2
	end
	return mean, math.sqrt(squares / (n - 1))
end

return Statistics
