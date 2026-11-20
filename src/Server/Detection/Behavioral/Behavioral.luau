--!strict
--[[
	Behavioral: statistical detection over time (built-in, Category "Behavioral").
	The models are documented in BehavioralDetectors and docs/BEHAVIORAL.md.

	Data sources:
	  - Signals:  ACF:DefineSignal("Coins", options) and ACF:RecordSignal(player, "Coins", n)
	              from the game's own server code (resource gain, XP, progression).
	  - Actions:  ACF:RecordAction(player, "Click", valid?) for timing regularity and
	              repeated invalid actions.
	  - Combat:   the Combat module's "Combat.Shot" topic (server-validated shots), when
	              Combat is running. Nothing comes from the client.

	Nothing here acts on one observation: signals need a CUSUM alarm over several buckets,
	ratios need a Wilson lower bound over a minimum sample, timing needs full windows, and
	every violation still goes through a decaying ViolationTracker before it is reported.
	Statistical evidence is capped at MaxConfidence 0.8 by default.
]]

local Configuration = require(script.Parent.Parent.Parent.Core.Configuration)
local Statistics = require(script.Parent.Parent.Parent.Intelligence.Statistics)
local ViolationTracker = require(script.Parent.Parent.Parent.Intelligence.ViolationTracker)
local BehavioralDetectors = require(script.Parent.BehavioralDetectors)

local S = Configuration.Schema

local MODULE_NAME = "Behavioral"
local STATE_KEY = "Behavioral.State"
local SHOT_TOPIC = "Combat.Shot"
local MAX_NAME_LENGTH = 64
local MAX_AMOUNT = 1e12

local CONFIG_SCHEMA = S.Table({
	Signals = S.Table({
		BucketSeconds = S.Number(10, { Min = 1, Max = 3600 }),
		SelfAlpha = S.Number(0.2, { Min = 0.01, Max = 1 }),
		MinPlayerBuckets = S.Number(3, { Min = 1, Max = 1000, Integer = true }),
		ActiveWithinBuckets = S.Number(6, { Min = 1, Max = 1000, Integer = true }),
		MinContributors = S.Number(4, { Min = 2, Max = 1000, Integer = true }),
		MinRelativeStdDev = S.Number(0.1, { Min = 0, Max = 10 }),
		ZClamp = S.Number(3, { Min = 1, Max = 20 }),
		CusumK = S.Number(0.5, { Min = 0, Max = 10 }),
		CusumH = S.Number(6, { Min = 0.5, Max = 1000 }),
		MinRatio = S.Number(3, { Min = 1, Max = 1000 }),
		HardLimitTolerance = S.Number(0.1, { Min = 0, Max = 10 }),
		MaxSignals = S.Number(64, { Min = 1, Max = 1024, Integer = true }),
	}),
	Accuracy = S.Table({
		HalfLifeSeconds = S.Number(600, { Min = 10, Max = 86400 }),
		EvaluateIntervalSeconds = S.Number(10, { Min = 1, Max = 3600 }),
		ConfidenceZ = S.Number(3.09, { Min = 1, Max = 6 }),
		MinShots = S.Number(40, { Min = 5, Max = 100000 }),
		AccuracyMargin = S.Number(0.35, { Min = 0, Max = 1 }),
		AccuracyFloor = S.Number(0.9, { Min = 0, Max = 1 }),
		AccuracyFloorWithoutBaseline = S.Number(0.95, { Min = 0, Max = 1 }),
		MinPopulationShots = S.Number(200, { Min = 1, Max = 1e7 }),
		MinHits = S.Number(20, { Min = 5, Max = 100000 }),
		HeadshotMargin = S.Number(0.4, { Min = 0, Max = 1 }),
		HeadshotFloor = S.Number(0.75, { Min = 0, Max = 1 }),
		HeadshotFloorWithoutBaseline = S.Number(0.9, { Min = 0, Max = 1 }),
		MinPopulationHits = S.Number(100, { Min = 1, Max = 1e7 }),
	}),
	Actions = S.Table({
		WindowSize = S.Number(30, { Min = 5, Max = 1000, Integer = true }),
		MaxCV = S.Number(0.02, { Min = 0, Max = 1 }),
		MinMeanIntervalSeconds = S.Number(0.1, { Min = 0, Max = 3600 }),
		MaxMeanIntervalSeconds = S.Number(10, { Min = 0.01, Max = 86400 }),
		MaxGapSeconds = S.Number(30, { Min = 0.1, Max = 86400 }),
		InvalidHalfLifeSeconds = S.Number(60, { Min = 1, Max = 86400 }),
		MinInvalid = S.Number(20, { Min = 1, Max = 100000 }),
		MaxInvalidRatio = S.Number(0.8, { Min = 0, Max = 1 }),
		InvalidConfidenceZ = S.Number(2.33, { Min = 1, Max = 6 }),
		MaxActionsPerPlayer = S.Number(32, { Min = 1, Max = 1024, Integer = true }),
	}),
	Detectors = S.Table({
		SignalRateLimit = S.Boolean(true),
		SignalAnomaly = S.Boolean(true),
		Accuracy = S.Boolean(true),
		Headshots = S.Boolean(true),
		Timing = S.Boolean(true),
		InvalidActions = S.Boolean(true),
	}),
	Severity = S.Table({
		SignalRateLimit = S.Number(30, { Min = 0, Max = 100 }),
		SignalAnomaly = S.Number(30, { Min = 0, Max = 100 }),
		Accuracy = S.Number(30, { Min = 0, Max = 100 }),
		Headshots = S.Number(30, { Min = 0, Max = 100 }),
		Timing = S.Number(15, { Min = 0, Max = 100 }),
		InvalidActions = S.Number(10, { Min = 0, Max = 100 }),
	}),
	Violation = S.Table({
		HalfLifeSeconds = S.Number(120, { Min = 1, Max = 86400 }),
		ReportThreshold = S.Number(3, { Min = 0.1, Max = 10000 }),
		ReportIntervalSeconds = S.Number(60, { Min = 0, Max = 86400 }),
		ConfidenceScale = S.Number(3, { Min = 0.1, Max = 10000 }),
		MaxConfidence = S.Number(0.8, { Min = 0, Max = 1 }),
	}),
})

type Definition = BehavioralDetectors.SignalDefinition

type SessionState = {
	tracker: ViolationTracker.ViolationTracker,
	signals: { [string]: BehavioralDetectors.SignalPlayer },
	weapons: { [string]: BehavioralDetectors.HitCounts },
	actions: { [string]: BehavioralDetectors.ActionState },
	actionCount: number,
}

local Behavioral = {}
Behavioral.Name = MODULE_NAME
Behavioral.ConfigSchema = CONFIG_SCHEMA

local function validName(name: any): boolean
	return type(name) == "string" and #name > 0 and #name <= MAX_NAME_LENGTH
end

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function normalizeSignal(name: string, options: any): Definition
	if not validName(name) then
		error("ACF Behavioral: signal name must be a string of 1-64 characters", 3)
	end
	options = options or {}
	if type(options) ~= "table" then
		error(`ACF Behavioral: options for signal '{name}' must be a table`, 3)
	end
	for key in options do
		if key ~= "MaxPerSecond" and key ~= "Baseline" and key ~= "MinStdDev" and key ~= "Statistical" then
			error(`ACF Behavioral: unknown option '{tostring(key)}' for signal '{name}'`, 3)
		end
	end
	local maxPerSecond = options.MaxPerSecond
	if maxPerSecond ~= nil and not (finite(maxPerSecond) and maxPerSecond > 0) then
		error(`ACF Behavioral: signal '{name}' MaxPerSecond must be a positive number`, 3)
	end
	local baseline = options.Baseline
	if baseline ~= nil then
		if type(baseline) ~= "table" or not finite(baseline.Mean) or baseline.Mean < 0 or not finite(baseline.StdDev) or baseline.StdDev <= 0 then
			error(`ACF Behavioral: signal '{name}' Baseline must be {"{"} Mean >= 0, StdDev > 0 {"}"}`, 3)
		end
		baseline = { Mean = baseline.Mean, StdDev = baseline.StdDev }
	end
	local minStdDev = options.MinStdDev or 0
	if not finite(minStdDev) or minStdDev < 0 then
		error(`ACF Behavioral: signal '{name}' MinStdDev must be a number >= 0`, 3)
	end
	local statistical = options.Statistical
	if statistical ~= nil and type(statistical) ~= "boolean" then
		error(`ACF Behavioral: signal '{name}' Statistical must be a boolean`, 3)
	end
	return table.freeze({
		Name = name,
		MaxPerSecond = maxPerSecond,
		Baseline = if baseline then table.freeze(baseline) else nil,
		MinStdDev = minStdDev,
		Statistical = statistical ~= false,
	}) :: any
end

function Behavioral.new()
	local module: any = {
		Name = MODULE_NAME,
		Version = "1.0.0",
		Category = "Behavioral",
		EnabledByDefault = true,
		ConfigSchema = CONFIG_SCHEMA,
	}

	local context: any = nil
	local running = false
	local definitions: { [string]: Definition } = {}
	local signalCount = 0
	local population: { [string]: BehavioralDetectors.HitCounts } = {}
	local baselines: { [string]: BehavioralDetectors.Baseline } = {}
	local accuracySettings: any = nil
	local actionSettings: any = nil
	local combatConnected = false
	local stats = { Violations = {} :: { [string]: number }, Reports = 0, ShotsObserved = 0, ActionsDropped = 0 }

	local function stateFor(session: any): SessionState
		return session:GetState(STATE_KEY, function()
			return {
				tracker = ViolationTracker.new(context.Config.Violation),
				signals = {},
				weapons = {},
				actions = {},
				actionCount = 0,
			}
		end)
	end

	local function handle(session: any, state: SessionState, violation: BehavioralDetectors.Violation, subject: string, now: number)
		local config = context.Config
		if not config.Detectors[violation.Detector] then
			return
		end
		stats.Violations[violation.Detector] = (stats.Violations[violation.Detector] or 0) + 1
		local report, score, confidence = state.tracker:Record(`{violation.Detector}:{subject}`, violation.Weight, now)
		if report then
			stats.Reports += 1
			local details = table.clone(violation.Details)
			details.Score = math.floor(score * 100) / 100
			context:Report(session, {
				Kind = violation.Kind,
				Severity = config.Severity[violation.Detector],
				Confidence = confidence,
				Details = details,
			})
		end
	end

	-- Signals ----------------------------------------------------------------------

	local function closeSignals(now: number)
		local settings = context.Config.Signals
		local sessions = context.Players:GetSessions()
		for name, definition in definitions do
			local players: { BehavioralDetectors.SignalPlayer } = {}
			local active: { { session: any, state: SessionState, player: BehavioralDetectors.SignalPlayer, rate: number } } = {}
			for _, session in sessions do
				local state = stateFor(session)
				local player = state.signals[name]
				if player then
					local rate = BehavioralDetectors.closeBucket(player, now, settings)
					table.insert(players, player)
					if rate and BehavioralDetectors.recentlyActive(player, settings) then
						table.insert(active, { session = session, state = state, player = player, rate = rate })
					end
				end
			end

			local baseline: BehavioralDetectors.Baseline? = nil
			local fixed = definition.Baseline
			if fixed then
				baseline = {
					Mean = fixed.Mean,
					Scale = math.max(fixed.StdDev, definition.MinStdDev),
					Players = 0,
					Source = "Defined",
				}
			else
				baseline = BehavioralDetectors.populationBaseline(players, settings, definition.MinStdDev)
			end
			if baseline then
				baselines[name] = baseline
			end

			for _, entry in active do
				local violations = BehavioralDetectors.evaluateSignal(definition, entry.player, entry.rate, baseline, settings)
				for _, violation in violations do
					handle(entry.session, entry.state, violation, name, now)
				end
			end
		end
	end

	-- Combat accuracy --------------------------------------------------------------

	local function onShot(payload: any)
		if not running or type(payload) ~= "table" then
			return
		end
		local kind = payload.WeaponKind
		if kind ~= "Hitscan" and kind ~= "Projectile" then
			return
		end
		local session = payload.Session
		local weapon = payload.Weapon
		if session == nil or type(weapon) ~= "string" then
			return
		end
		local now = context.Clock.Now()
		local halfLife = accuracySettings.HalfLifeSeconds
		local state = stateFor(session)
		local counts = state.weapons[weapon]
		if counts == nil then
			counts = BehavioralDetectors.newCounts(now)
			state.weapons[weapon] = counts
		end
		local totals = population[weapon]
		if totals == nil then
			totals = BehavioralDetectors.newCounts(now)
			population[weapon] = totals
		end
		BehavioralDetectors.ageCounts(counts, now, halfLife)
		BehavioralDetectors.ageCounts(totals, now, halfLife)

		local hit = payload.Hit == true
		local head = hit and payload.Headshot == true
		if payload.Event == "Shot" then
			stats.ShotsObserved += 1
			counts.Shots += 1
			totals.Shots += 1
		elseif payload.Event ~= "Hit" then
			return
		end
		if hit then
			counts.Hits += 1
			totals.Hits += 1
			if head then
				counts.Heads += 1
				totals.Heads += 1
			end
		end
	end

	local function evaluate(now: number)
		local config = context.Config
		local halfLife = accuracySettings.HalfLifeSeconds
		for _, totals in population do
			BehavioralDetectors.ageCounts(totals, now, halfLife)
		end
		for _, session in context.Players:GetSessions() do
			local state = stateFor(session)
			if config.Detectors.Accuracy or config.Detectors.Headshots then
				for weapon, counts in state.weapons do
					BehavioralDetectors.ageCounts(counts, now, halfLife)
					local totals = population[weapon]
					if totals then
						for _, violation in BehavioralDetectors.evaluateAccuracy(weapon, counts, totals, accuracySettings) do
							handle(session, state, violation, weapon, now)
						end
					end
				end
			end
			if config.Detectors.InvalidActions then
				for action, actionState in state.actions do
					local violation = BehavioralDetectors.evaluateInvalid(actionState, action, now, actionSettings)
					if violation then
						handle(session, state, violation, action, now)
					end
				end
			end
		end
	end

	-- Public surface -----------------------------------------------------------------

	-- Declares a game signal. options: { MaxPerSecond?, Baseline? = { Mean, StdDev }
	-- (per second), MinStdDev?, Statistical? = true }.
	function module:DefineSignal(name: string, options: any)
		if definitions[name] ~= nil then
			error(`ACF Behavioral: signal '{tostring(name)}' is already defined`, 2)
		end
		local maxSignals = if context then context.Config.Signals.MaxSignals else 64
		if signalCount >= maxSignals then
			error(`ACF Behavioral: at most {maxSignals} signals can be defined`, 2)
		end
		definitions[name] = normalizeSignal(name, options)
		signalCount += 1
	end

	function module:IsSignalDefined(name: string): boolean
		return definitions[name] ~= nil
	end

	-- Adds `amount` (>= 0) to the player's signal. Returns false when not recorded.
	function module:RecordSignal(player: any, name: string, amount: number): boolean
		if definitions[name] == nil then
			error(`ACF Behavioral: signal '{tostring(name)}' is not defined (call DefineSignal first)`, 2)
		end
		if not running or not finite(amount) or amount < 0 or amount > MAX_AMOUNT then
			return false
		end
		local session = context.Players:GetSession(player)
		if session == nil then
			return false
		end
		local state = stateFor(session)
		local signal = state.signals[name]
		if signal == nil then
			signal = BehavioralDetectors.newSignalPlayer()
			state.signals[name] = signal
		end
		BehavioralDetectors.recordSignal(signal, amount)
		return true
	end

	-- Records one game action. valid = false marks an action the game's own client
	-- should never produce (see docs/BEHAVIORAL.md). Returns false when not recorded.
	function module:RecordAction(player: any, action: string, valid: boolean?): boolean
		if not validName(action) then
			error("ACF Behavioral: action name must be a string of 1-64 characters", 2)
		end
		if not running then
			return false
		end
		local session = context.Players:GetSession(player)
		if session == nil then
			return false
		end
		local now = context.Clock.Now()
		local state = stateFor(session)
		local actionState = state.actions[action]
		if actionState == nil then
			if state.actionCount >= actionSettings.MaxActionsPerPlayer then
				stats.ActionsDropped += 1
				return false
			end
			actionState = BehavioralDetectors.newActionState(now)
			state.actions[action] = actionState
			state.actionCount += 1
		end
		local violation = BehavioralDetectors.recordAction(actionState, action, valid ~= false, now, actionSettings)
		if violation then
			handle(session, state, violation, action, now)
		end
		return true
	end

	-- Snapshot of one player's behavioural statistics (diagnostics, Phase 6 risk input).
	function module:GetProfile(target: any): { [string]: any }?
		if context == nil then
			return nil
		end
		local session = context.Players:GetSession(target)
		if session == nil then
			return nil
		end
		local now = context.Clock.Now()
		local state = stateFor(session)
		local signals = {}
		for name, signal in state.signals do
			signals[name] = {
				MeanRate = signal.Self.Mean,
				StdDev = Statistics.stdDev(signal.Self),
				ActiveBuckets = signal.ActiveBuckets,
				LastRate = signal.LastRate,
				LastZ = signal.LastZ,
				Cusum = signal.Cusum.S,
			}
		end
		local weapons = {}
		for weapon, counts in state.weapons do
			local factor = Statistics.decayFactor(now - counts.Updated, accuracySettings.HalfLifeSeconds)
			local shots, hits, heads = counts.Shots * factor, counts.Hits * factor, counts.Heads * factor
			weapons[weapon] = {
				Shots = shots,
				Hits = hits,
				Headshots = heads,
				Accuracy = if shots > 0 then math.min(1, hits / shots) else nil,
				HeadshotRatio = if hits > 0 then math.min(1, heads / hits) else nil,
			}
		end
		local actions = {}
		for action, actionState in state.actions do
			local mean, std = Statistics.meanStd(actionState.Intervals)
			local factor = Statistics.decayFactor(now - actionState.Updated, actionSettings.InvalidHalfLifeSeconds)
			actions[action] = {
				Intervals = #actionState.Intervals,
				MeanInterval = if #actionState.Intervals > 0 then mean else nil,
				CV = if #actionState.Intervals > 1 and mean > 0 then std / mean else nil,
				Invalid = actionState.Invalid * factor,
				Total = actionState.Total * factor,
			}
		end
		return { Signals = signals, Weapons = weapons, Actions = actions }
	end

	-- The most recent baseline used for a signal, or nil before one exists.
	function module:GetBaseline(name: string): { [string]: any }?
		local baseline = baselines[name]
		return if baseline then table.clone(baseline) else nil
	end

	function module:GetStats(): { [string]: any }
		local signals = {}
		for name, definition in definitions do
			local baseline = baselines[name]
			signals[name] = {
				MaxPerSecond = definition.MaxPerSecond,
				BaselineSource = if baseline then baseline.Source else nil,
				BaselineMean = if baseline then baseline.Mean else nil,
				BaselinePlayers = if baseline then baseline.Players else nil,
			}
		end
		return {
			Signals = signals,
			CombatConnected = combatConnected,
			ShotsObserved = stats.ShotsObserved,
			ActionsDropped = stats.ActionsDropped,
			Violations = table.clone(stats.Violations),
			Reports = stats.Reports,
		}
	end

	-- Lifecycle ----------------------------------------------------------------------

	function module:Initialize(ctx)
		context = ctx
		local config = ctx.Config
		accuracySettings = table.clone(config.Accuracy)
		accuracySettings.CheckAccuracy = config.Detectors.Accuracy
		accuracySettings.CheckHeadshots = config.Detectors.Headshots
		actionSettings = table.clone(config.Actions)
		actionSettings.CheckTiming = config.Detectors.Timing
		if signalCount > config.Signals.MaxSignals then
			error(`ACF Behavioral: {signalCount} signals defined, MaxSignals is {config.Signals.MaxSignals}`)
		end
	end

	function module:Start()
		local config = context.Config
		running = true
		combatConnected = false
		if context.Events:Has(SHOT_TOPIC) then
			context.Events:Subscribe(SHOT_TOPIC, onShot)
			combatConnected = true
		end
		context.Scheduler:Every("Signals", config.Signals.BucketSeconds, closeSignals)
		context.Scheduler:Every("Evaluate", config.Accuracy.EvaluateIntervalSeconds, evaluate)
	end

	function module:Stop()
		running = false
		combatConnected = false
	end

	function module:Destroy()
		running = false
		context = nil
	end

	return module
end

return Behavioral
