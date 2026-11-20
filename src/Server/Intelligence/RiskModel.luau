--!strict
--[[
	Pure risk mathematics. No clocks, no Roblox: RiskEngine passes times in.

	Evidence key: one (Detector, Kind) pair for one user. Its score decays exponentially
	with half-life H (lambda = ln 2 / H) and grows with each accepted detection:

	    S <- S * 0.5^(dt / H)                                    (decay)
	    S <- S + w * c * max(0, 1 - S / (w * c * RepeatCap))     (saturating add)

	w = detection severity (0-100) and c = confidence (0-1). The first detection adds
	exactly w * c, matching R = sum(w_i * c_i * exp(-lambda * t_i)). Repeats of the SAME
	kind have diminishing returns and approach w * c * RepeatCap, so one cheat repeating
	forever cannot climb the bands on its own: duplicate suppression.

	Correlation group: kinds that observe the same underlying behaviour (Movement and
	Physics; accuracy and headshots) are grouped. Within a group the strongest key counts
	fully and the rest at SecondaryWeight:

	    G = max(S_k) + SecondaryWeight * (sum(S_k) - max(S_k))

	so one teleport that also trips speed and velocity-mismatch checks is not counted
	three times.

	Risk:        R = min(100, sum over groups G + persistent)
	Confidence:  noisy-OR over groups of each group's strongest confidence,
	             1 - prod(1 - c_g). Groups are treated as independent evidence, which
	             is exactly why correlated kinds are grouped first.
]]

local RiskModel = {}

export type Key = {
	Detector: string,
	Kind: string,
	Category: string,
	Group: string,
	Score: number,
	Updated: number,
	Severity: number,
	Confidence: number,
	Count: number,
	Suppressed: number,
	LastAccepted: number,
}

export type GroupSummary = {
	Group: string,
	Score: number,
	Confidence: number,
	Keys: { Key },
}

RiskModel.BANDS = table.freeze({ "Normal", "Increased", "Restrict", "Investigation", "EnforcementReview" })

function RiskModel.decay(score: number, elapsed: number, halfLife: number): number
	if elapsed <= 0 then
		return score
	end
	return score * 0.5 ^ (elapsed / halfLife)
end

-- Ages a key to `now`.
function RiskModel.age(key: Key, now: number, halfLife: number)
	if now > key.Updated then
		key.Score = RiskModel.decay(key.Score, now - key.Updated, halfLife)
		key.Updated = now
	end
end

-- Adds one detection to a key (already aged to `now`). Returns the contribution.
function RiskModel.add(key: Key, severity: number, confidence: number, repeatCap: number): number
	local base = severity * confidence
	if base <= 0 then
		return 0
	end
	local cap = base * repeatCap
	local contribution = base * math.max(0, 1 - key.Score / cap)
	key.Score += contribution
	key.Count += 1
	key.Severity = math.max(key.Severity, severity)
	key.Confidence = math.max(key.Confidence, confidence)
	return contribution
end

-- Resolves the correlation group for a detection: "Detector.Kind", then Detector, then
-- Category in `groups`; otherwise the category itself.
function RiskModel.groupFor(detector: string, kind: string, category: string, groups: { [string]: string }): string
	return groups[`{detector}.{kind}`] or groups[detector] or groups[category] or category
end

-- Combines keys into groups. Keys must be aged to the same time.
function RiskModel.summarize(keys: { Key }, secondaryWeight: number): { GroupSummary }
	local byGroup: { [string]: GroupSummary } = {}
	local sums: { [string]: number } = {}
	local maxima: { [string]: number } = {}
	for _, key in keys do
		local summary = byGroup[key.Group]
		if summary == nil then
			summary = { Group = key.Group, Score = 0, Confidence = 0, Keys = {} }
			byGroup[key.Group] = summary
			sums[key.Group] = 0
			maxima[key.Group] = 0
		end
		table.insert(summary.Keys, key)
		sums[key.Group] += key.Score
		if key.Score > maxima[key.Group] then
			maxima[key.Group] = key.Score
			summary.Confidence = key.Confidence
		end
	end
	local list: { GroupSummary } = {}
	for name, summary in byGroup do
		summary.Score = maxima[name] + secondaryWeight * (sums[name] - maxima[name])
		table.sort(summary.Keys, function(a, b)
			return a.Score > b.Score
		end)
		table.insert(list, summary)
	end
	table.sort(list, function(a, b)
		if a.Score ~= b.Score then
			return a.Score > b.Score
		end
		return a.Group < b.Group
	end)
	return list
end

-- Total risk (0-100) and noisy-OR confidence from group summaries.
function RiskModel.combine(groups: { GroupSummary }, persistent: number): (number, number)
	local total = persistent
	local miss = 1
	for _, group in groups do
		total += group.Score
		miss *= 1 - math.clamp(group.Confidence, 0, 1)
	end
	return math.min(100, math.max(0, total)), 1 - miss
end

-- Band name for a risk value. thresholds = { Increased, Restrict, Investigation,
-- EnforcementReview } lower bounds.
function RiskModel.band(risk: number, thresholds: { [string]: number }): string
	if risk >= thresholds.EnforcementReview then
		return "EnforcementReview"
	elseif risk >= thresholds.Investigation then
		return "Investigation"
	elseif risk >= thresholds.Restrict then
		return "Restrict"
	elseif risk >= thresholds.Increased then
		return "Increased"
	end
	return "Normal"
end

function RiskModel.bandIndex(band: string): number
	return table.find(RiskModel.BANDS, band) or 1
end

local function round(value: number): number
	return math.floor(value * 10 + 0.5) / 10
end

-- One human-readable line per group, strongest first, e.g.
-- "Movement 41.2: TeleportDetected x6 (Movement, sev 30, conf 0.71) + SpeedExceeded x2".
function RiskModel.explain(risk: number, band: string, groups: { GroupSummary }, persistent: number): string
	local lines = { `Risk {round(risk)} ({band})` }
	for _, group in groups do
		local parts = {}
		for index, key in group.Keys do
			if index > 3 then
				table.insert(parts, `+{#group.Keys - 3} more`)
				break
			end
			table.insert(
				parts,
				`{key.Kind} x{key.Count} ({key.Detector}, sev {key.Severity}, conf {round(key.Confidence * 100) / 100}, {round(key.Score)})`
			)
		end
		table.insert(lines, `  {group.Group} {round(group.Score)}: {table.concat(parts, " + ")}`)
	end
	if persistent > 0 then
		table.insert(lines, `  History {round(persistent)}: risk carried from earlier sessions`)
	end
	return table.concat(lines, "\n")
end

return RiskModel
