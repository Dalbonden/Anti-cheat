--!strict
--[[
	Pure enforcement policy: risk report + offence history + configuration -> decision.
	No clocks and no side effects; EnforcementManager applies the result.

	Levels:
	  0 Logging                1 Increased monitoring      2 Reject suspicious actions
	  3 Server-side correction 4 Temporary restriction     5 Kick
	  6 Temporary ban          7 Permanent ban

	Levels 0-4 never remove a player. Their only effects are on tagged operations
	(restriction tags) and movement correction. They come from the risk band
	(Enforcement.BandLevels) in Hybrid and Manual modes.

	Levels 5-7 are proposed only at the EnforcementReview band. The candidate escalates
	with the offence history: kicks within RepeatWindowDays lead to a temporary ban, and
	temporary bans to a permanent-ban proposal. A candidate runs automatically only when
	ALL of these hold:
	  - Mode = Hybrid;
	  - its switch is on (AutoKick for 5; AutoBan for 6; AutoBan and NOT
	    RequireApprovalForPermanentBan for 7);
	  - the evidence is corroborated:
	      * confidence >= MinConfidence, AND
	      * one non-statistical group >= HardEvidenceMinScore, OR >= MinIndependentGroups
	        qualifying groups of which at least one is non-statistical.
	    Behavioural statistics (Aim, Economy, Automation) alone never corroborate.
	Otherwise it becomes a proposal awaiting staff approval (a case).
]]

local EnforcementPolicy = {}

EnforcementPolicy.LEVEL_NAMES = table.freeze({
	[0] = "Logging",
	[1] = "Monitoring",
	[2] = "Rejection",
	[3] = "Correction",
	[4] = "Restriction",
	[5] = "Kick",
	[6] = "TemporaryBan",
	[7] = "PermanentBan",
})

export type Input = {
	Band: string,
	Risk: number,
	Confidence: number,
	Groups: { { Group: string, Score: number } },
	RecentKicks: number,
	TemporaryBans: number,
}

export type Decision = {
	-- Level applied automatically (0-4, or 5-7 when allowed).
	Level: number,
	-- Groups at or above TagMinScore: operations tagged with these are restricted.
	Tags: { string },
	-- Level 5-7 candidate needing staff approval, or nil.
	Proposed: number?,
	Corroborated: boolean,
	Reason: string,
}

function EnforcementPolicy.levelName(level: number): string
	return EnforcementPolicy.LEVEL_NAMES[level] or tostring(level)
end

-- Whether the evidence may justify an automatic removal. Returns (ok, why).
function EnforcementPolicy.corroborated(input: Input, config: { [string]: any }): (boolean, string)
	local rules = config.Corroboration
	local statistical = config.StatisticalGroups
	if input.Confidence < rules.MinConfidence then
		return false, `confidence {math.floor(input.Confidence * 100) / 100} < {rules.MinConfidence}`
	end
	local qualifying, hardQualifying = 0, 0
	for _, group in input.Groups do
		local isStatistical = statistical[group.Group] == true
		if not isStatistical and group.Score >= rules.HardEvidenceMinScore then
			return true, `strong {group.Group} evidence ({math.floor(group.Score)})`
		end
		if group.Score >= config.TagMinScore then
			qualifying += 1
			if not isStatistical then
				hardQualifying += 1
			end
		end
	end
	if qualifying >= rules.MinIndependentGroups and hardQualifying >= 1 then
		return true, `{qualifying} independent groups`
	end
	if hardQualifying == 0 and qualifying > 0 then
		return false, "only statistical evidence"
	end
	return false, `{qualifying} independent group(s), need {rules.MinIndependentGroups}`
end

function EnforcementPolicy.decide(input: Input, config: { [string]: any }): Decision
	local tags = {}
	for _, group in input.Groups do
		if group.Score >= config.TagMinScore then
			table.insert(tags, group.Group)
		end
	end
	if config.Mode == "Off" then
		return { Level = 0, Tags = tags, Proposed = nil, Corroborated = false, Reason = "enforcement mode Off" }
	end

	local level = config.BandLevels[input.Band] or 0
	local ok, why = EnforcementPolicy.corroborated(input, config)
	if input.Band ~= "EnforcementReview" then
		return { Level = level, Tags = tags, Proposed = nil, Corroborated = ok, Reason = `band {input.Band}` }
	end

	local bans = config.Bans
	local candidate = 5
	if input.TemporaryBans >= bans.TempBansBeforePermanentProposal then
		candidate = 7
	elseif input.RecentKicks >= bans.KicksBeforeTempBan then
		candidate = 6
	end

	local automatic = false
	if config.Mode == "Hybrid" and ok then
		if candidate == 5 then
			automatic = config.AutoKick
		elseif candidate == 6 then
			automatic = config.AutoBan
		else
			automatic = config.AutoBan and not bans.RequireApprovalForPermanentBan
		end
	end

	local reason = `band EnforcementReview; {why}`
	if automatic then
		return { Level = candidate, Tags = tags, Proposed = nil, Corroborated = ok, Reason = reason }
	end
	return { Level = level, Tags = tags, Proposed = candidate, Corroborated = ok, Reason = reason }
end

return EnforcementPolicy
