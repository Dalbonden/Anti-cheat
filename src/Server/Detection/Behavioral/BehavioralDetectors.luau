--!strict
--[[
	Pure behavioural detectors. The Behavioral module owns state and timing; everything
	here takes values and times in and returns violations, so it is fully unit-tested.

	Signals (game-supplied rates: currency, XP, items, progression)
	  Input:  amounts recorded per player, closed into fixed buckets every BucketSeconds.
	          Every bucket after the player's first (partial) one counts, empty buckets
	          included, so a player paid in lumps (100 coins every 20 s) and one paid
	          steadily (5 per second) have the same mean rate.
	  Model:  each player keeps an EWMA mean/variance of their bucket rate. The baseline
	          is cross-sectional and robust: the MEDIAN of eligible players' means, with
	          scale = max(median per-player std, 1.4826 * MAD of means, MinStdDev,
	          MinRelativeStdDev * median). Eligible players have MinPlayerBuckets
	          buckets and activity within the last ActiveWithinBuckets buckets, so AFK
	          players do not drag the baseline down. One cheater cannot move a median:
	          the baseline assumes only that most players are honest. A game can
	          instead give a fixed Baseline { Mean, StdDev } (needed for small servers).
	          Each bucket of a recently active player is standardised (z, clamped to
	          ZClamp) and fed to an upper CUSUM (k = CusumK, h = CusumH); empty buckets
	          give negative z and pull it back down.
	  Output: SignalAnomaly when the CUSUM alarms AND the player's own mean is at least
	          MinRatio x the baseline (statistically and practically significant).
	          SignalRateLimit when a bucket's rate exceeds the game's MaxPerSecond.
	  Guard:  with ZClamp 3, k 0.5, h 6 an alarm needs three or more strongly anomalous
	          buckets; no single bucket can raise one.

	Accuracy (from Combat's server-validated shots; hitscan and projectile weapons)
	  Input:  per player and weapon, exponentially decayed counts of shots, character
	          hits and headshots; the same counts for the whole server.
	  Model:  Wilson lower bound (ConfidenceZ) of the player's hit ratio versus the
	          server's ratio for that weapon with the player's own shots removed, plus a
	          margin, never below a floor. Without enough population shots, only a high
	          absolute floor applies. Headshots per hit are judged the same way.
	  Output: AccuracyAnomaly / HeadshotAnomaly.
	  Guard:  MinShots / MinHits, and the lower bound itself: a skilled player with a
	          short hot streak has a wide interval and is not flagged.

	Timing (game-recorded actions: clicks, interactions, purchases)
	  Input:  intervals between consecutive actions of one kind; a gap longer than
	          MaxGapSeconds starts a new run.
	  Model:  coefficient of variation (std / mean) over non-overlapping windows of
	          WindowSize intervals.
	  Output: RegularTiming when CV < MaxCV for a window whose mean interval is within
	          [MinMeanIntervalSeconds, MaxMeanIntervalSeconds]. Human motor timing has a
	          CV of several percent even when deliberately rhythmic.

	Invalid actions (actions the game marks as impossible for its own client)
	  Model:  decayed invalid / total counts; Wilson lower bound of the invalid ratio.
	  Output: RepeatedInvalidActions when the bound exceeds MaxInvalidRatio with at
	          least MinInvalid decayed invalid actions.
]]

local Statistics = require(script.Parent.Parent.Parent.Intelligence.Statistics)

export type Violation = { Detector: string, Kind: string, Weight: number, Details: { [string]: any } }

export type SignalDefinition = {
	Name: string,
	MaxPerSecond: number?,
	Baseline: { Mean: number, StdDev: number }?,
	MinStdDev: number,
	Statistical: boolean,
}

export type SignalPlayer = {
	Sum: number,
	BucketStart: number?,
	Self: Statistics.Ewma,
	Cusum: Statistics.Cusum,
	LastRate: number?,
	LastZ: number?,
	ActiveBuckets: number,
	BucketsSinceActive: number,
}

export type Baseline = { Mean: number, Scale: number, Players: number, Source: string }

export type HitCounts = { Shots: number, Hits: number, Heads: number, Updated: number }

export type ActionState = {
	Last: number?,
	Intervals: { number },
	SinceEvaluation: number,
	Invalid: number,
	Total: number,
	Updated: number,
}

local BehavioralDetectors = {}

local function round(value: number, places: number?): number
	local factor = 10 ^ (places or 2)
	return math.floor(value * factor + 0.5) / factor
end

local function median(sorted: { number }): number
	local n = #sorted
	if n == 0 then
		return 0
	end
	local middle = (n + 1) // 2
	if n % 2 == 1 then
		return sorted[middle]
	end
	return (sorted[middle] + sorted[middle + 1]) / 2
end

-- Signals --------------------------------------------------------------------------

function BehavioralDetectors.newSignalPlayer(): SignalPlayer
	return {
		Sum = 0,
		BucketStart = nil,
		Self = Statistics.newEwma(),
		Cusum = Statistics.newCusum(),
		LastRate = nil,
		LastZ = nil,
		ActiveBuckets = 0,
		BucketsSinceActive = 0,
	}
end

function BehavioralDetectors.recordSignal(player: SignalPlayer, amount: number)
	player.Sum += amount
end

-- Closes the player's current bucket at `now` and returns its rate (sum / elapsed),
-- or nil. The first bucket after a player starts being tracked is partial and is
-- discarded; a bucket shorter than half of BucketSeconds keeps accumulating. Updates the
-- player's own EWMA with the rate, empty buckets included.
function BehavioralDetectors.closeBucket(player: SignalPlayer, now: number, settings: any): number?
	local start = player.BucketStart
	if start == nil then
		player.Sum = 0
		player.BucketStart = now
		return nil
	end
	local elapsed = now - start
	if elapsed < settings.BucketSeconds * 0.5 then
		return nil
	end
	local sum = player.Sum
	player.Sum = 0
	player.BucketStart = now
	local rate = sum / elapsed
	player.LastRate = rate
	if sum > 0 then
		player.ActiveBuckets += 1
		player.BucketsSinceActive = 0
	else
		player.BucketsSinceActive += 1
	end
	Statistics.updateEwma(player.Self, rate, settings.SelfAlpha)
	return rate
end

-- Whether a player has had activity within the last ActiveWithinBuckets buckets.
function BehavioralDetectors.recentlyActive(player: SignalPlayer, settings: any): boolean
	return player.ActiveBuckets > 0 and player.BucketsSinceActive < settings.ActiveWithinBuckets
end

-- Robust cross-sectional baseline from players with at least MinPlayerBuckets buckets
-- who were recently active. Nil when fewer than MinContributors players qualify.
function BehavioralDetectors.populationBaseline(players: { SignalPlayer }, settings: any, minStdDev: number): Baseline?
	local means: { number } = {}
	local stds: { number } = {}
	for _, player in players do
		if player.Self.Count >= settings.MinPlayerBuckets and BehavioralDetectors.recentlyActive(player, settings) then
			table.insert(means, player.Self.Mean)
			table.insert(stds, Statistics.stdDev(player.Self))
		end
	end
	if #means < settings.MinContributors then
		return nil
	end
	table.sort(means)
	table.sort(stds)
	local center = median(means)
	local deviations: { number } = {}
	for _, value in means do
		table.insert(deviations, math.abs(value - center))
	end
	table.sort(deviations)
	local mad = 1.4826 * median(deviations)
	local scale = math.max(median(stds), mad, minStdDev, settings.MinRelativeStdDev * math.abs(center))
	return { Mean = center, Scale = scale, Players = #means, Source = "Population" }
end

-- Evaluates one active bucket `rate` for a player against `baseline` (nil = none yet).
function BehavioralDetectors.evaluateSignal(
	definition: SignalDefinition,
	player: SignalPlayer,
	rate: number,
	baseline: Baseline?,
	settings: any
): { Violation }
	local violations: { Violation } = {}

	local limit = definition.MaxPerSecond
	if limit ~= nil and rate > limit * (1 + settings.HardLimitTolerance) then
		local ratio = rate / limit
		table.insert(violations, {
			Detector = "SignalRateLimit",
			Kind = "SignalRateLimit",
			Weight = math.clamp(ratio - 1, 1, 2),
			Details = {
				Signal = definition.Name,
				RatePerSecond = round(rate),
				MaxPerSecond = limit,
			},
		})
	end

	if baseline ~= nil and definition.Statistical then
		local z = Statistics.zScore(rate, baseline.Mean, baseline.Scale, 0, 0, settings.ZClamp)
		player.LastZ = z
		local alarm, statistic, steps = Statistics.cusumStep(player.Cusum, z, settings.CusumK, settings.CusumH)
		local ratio = if baseline.Mean > 0 then player.Self.Mean / baseline.Mean else math.huge
		if alarm and ratio >= settings.MinRatio then
			table.insert(violations, {
				Detector = "SignalAnomaly",
				Kind = "SignalAnomaly",
				Weight = 3,
				Details = {
					Signal = definition.Name,
					RatePerSecond = round(rate),
					PlayerMean = round(player.Self.Mean),
					BaselineMean = round(baseline.Mean),
					BaselineScale = round(baseline.Scale),
					BaselineSource = baseline.Source,
					BaselinePlayers = baseline.Players,
					Ratio = if ratio == math.huge then -1 else round(ratio),
					Cusum = round(statistic),
					Buckets = steps,
				},
			})
		end
	end
	return violations
end

-- Accuracy -------------------------------------------------------------------------

function BehavioralDetectors.newCounts(now: number): HitCounts
	return { Shots = 0, Hits = 0, Heads = 0, Updated = now }
end

function BehavioralDetectors.ageCounts(counts: HitCounts, now: number, halfLife: number)
	local factor = Statistics.decayFactor(now - counts.Updated, halfLife)
	if factor < 1 then
		counts.Shots *= factor
		counts.Hits *= factor
		counts.Heads *= factor
	end
	if now > counts.Updated then
		counts.Updated = now
	end
end

local function ratioCheck(
	successes: number,
	trials: number,
	popSuccesses: number,
	popTrials: number,
	z: number,
	margin: number,
	floor: number,
	floorWithoutBaseline: number,
	minPopulation: number
): (boolean, { [string]: any })
	local lower = Statistics.wilsonLower(successes, trials, z)
	local threshold, basis, popRatio
	if popTrials >= minPopulation then
		popRatio = popSuccesses / popTrials
		threshold = math.max(popRatio + margin, floor)
		basis = "Population"
	else
		threshold = floorWithoutBaseline
		basis = "Absolute"
	end
	return lower > threshold,
		{
			Ratio = round(successes / trials, 3),
			LowerBound = round(lower, 3),
			Threshold = round(threshold, 3),
			PopulationRatio = if popRatio then round(popRatio, 3) else nil,
			Basis = basis,
		}
end

-- Compares a player's counts for one weapon with the population counts for that weapon
-- (which include the player; their own share is subtracted). Both must be aged to the
-- same time with the same half-life.
function BehavioralDetectors.evaluateAccuracy(weapon: string, player: HitCounts, population: HitCounts, settings: any): { Violation }
	local violations: { Violation } = {}
	local popShots = math.max(0, population.Shots - player.Shots)
	local popHits = math.max(0, population.Hits - player.Hits)
	local popHeads = math.max(0, population.Heads - player.Heads)

	if settings.CheckAccuracy and player.Shots >= settings.MinShots then
		local flagged, details = ratioCheck(
			math.min(player.Hits, player.Shots),
			player.Shots,
			math.min(popHits, popShots),
			popShots,
			settings.ConfidenceZ,
			settings.AccuracyMargin,
			settings.AccuracyFloor,
			settings.AccuracyFloorWithoutBaseline,
			settings.MinPopulationShots
		)
		if flagged then
			details.Weapon = weapon
			details.Shots = round(player.Shots, 1)
			details.Hits = round(player.Hits, 1)
			table.insert(violations, { Detector = "Accuracy", Kind = "AccuracyAnomaly", Weight = 1, Details = details })
		end
	end

	if settings.CheckHeadshots and player.Hits >= settings.MinHits then
		local flagged, details = ratioCheck(
			math.min(player.Heads, player.Hits),
			player.Hits,
			math.min(popHeads, popHits),
			popHits,
			settings.ConfidenceZ,
			settings.HeadshotMargin,
			settings.HeadshotFloor,
			settings.HeadshotFloorWithoutBaseline,
			settings.MinPopulationHits
		)
		if flagged then
			details.Weapon = weapon
			details.Hits = round(player.Hits, 1)
			details.Headshots = round(player.Heads, 1)
			table.insert(violations, { Detector = "Headshots", Kind = "HeadshotAnomaly", Weight = 1, Details = details })
		end
	end
	return violations
end

-- Actions --------------------------------------------------------------------------

function BehavioralDetectors.newActionState(now: number): ActionState
	return { Last = nil, Intervals = {}, SinceEvaluation = 0, Invalid = 0, Total = 0, Updated = now }
end

-- Records one action. Returns a RegularTiming violation when a full window is too
-- regular (only when settings.CheckTiming is true).
function BehavioralDetectors.recordAction(state: ActionState, action: string, valid: boolean, now: number, settings: any): Violation?
	-- Validity counts (decayed).
	local factor = Statistics.decayFactor(now - state.Updated, settings.InvalidHalfLifeSeconds)
	state.Invalid *= factor
	state.Total *= factor
	if now > state.Updated then
		state.Updated = now
	end
	state.Total += 1
	if not valid then
		state.Invalid += 1
	end

	-- Timing.
	local last = state.Last
	state.Last = now
	if last == nil then
		return nil
	end
	local interval = now - last
	local intervals = state.Intervals
	if interval > settings.MaxGapSeconds or interval < 0 then
		table.clear(intervals)
		state.SinceEvaluation = 0
		return nil
	end
	table.insert(intervals, interval)
	if #intervals > settings.WindowSize then
		table.remove(intervals, 1)
	end
	state.SinceEvaluation += 1
	if not settings.CheckTiming or #intervals < settings.WindowSize or state.SinceEvaluation < settings.WindowSize then
		return nil
	end
	state.SinceEvaluation = 0

	local mean, std = Statistics.meanStd(intervals)
	if mean < settings.MinMeanIntervalSeconds or mean > settings.MaxMeanIntervalSeconds then
		return nil
	end
	local cv = std / mean
	if cv >= settings.MaxCV then
		return nil
	end
	return {
		Detector = "Timing",
		Kind = "RegularTiming",
		Weight = 1.5,
		Details = {
			Action = action,
			Samples = #intervals,
			MeanInterval = round(mean, 4),
			StdDev = round(std, 4),
			CV = round(cv, 4),
		},
	}
end

-- Invalid-action ratio check for one action kind, aged to `now`.
function BehavioralDetectors.evaluateInvalid(state: ActionState, action: string, now: number, settings: any): Violation?
	local factor = Statistics.decayFactor(now - state.Updated, settings.InvalidHalfLifeSeconds)
	local invalid, total = state.Invalid * factor, state.Total * factor
	if invalid < settings.MinInvalid or total <= 0 then
		return nil
	end
	local lower = Statistics.wilsonLower(invalid, total, settings.InvalidConfidenceZ)
	if lower <= settings.MaxInvalidRatio then
		return nil
	end
	return {
		Detector = "InvalidActions",
		Kind = "RepeatedInvalidActions",
		Weight = 1,
		Details = {
			Action = action,
			Invalid = round(invalid, 1),
			Total = round(total, 1),
			LowerBound = round(lower, 3),
			MaxRatio = settings.MaxInvalidRatio,
		},
	}
end

return BehavioralDetectors
