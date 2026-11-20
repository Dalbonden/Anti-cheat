--!strict
--[[
	Movement: server-observed movement validation (built-in, Category "Movement").

	Every SampleIntervalSeconds the module samples each character through
	Environment.Physics (root position/velocity, humanoid state, ground clearance) and
	runs MovementDetectors. Violations feed a per-player ViolationTracker; only sustained
	evidence is reported. A single unusual position update never is.

	Legitimate movement handled explicitly:
	  - Respawn / character replacement: state resets whenever CharacterGeneration changes.
	  - Seats and vehicles: detectors pause while seated; history resets on leaving.
	  - Death: detectors pause; history resets.
	  - Climbing and swimming: exempt from flight / air-jump checks.
	  - Falling: speed is horizontal; downward motion is never a violation.
	  - Server WalkSpeed changes: the allowed speed follows the server-side WalkSpeed.
	  - Latency: ping compensation plus "time credit" after freezes (see MovementDetectors).
	  - Game mechanics: AuthorizeTeleport(player) and Allow(player, kind, seconds) for
	    teleports, dashes/speed boosts, jetpacks, knockback and scripted noclip.

	Each sample is published on "Movement.Sample" for dependent modules (Physics).
]]

local Configuration = require(script.Parent.Parent.Parent.Core.Configuration)
local ViolationTracker = require(script.Parent.Parent.Parent.Intelligence.ViolationTracker)
local MovementDetectors = require(script.Parent.MovementDetectors)

local S = Configuration.Schema

local MODULE_NAME = "Movement"
local STATE_KEY = "Movement.State"

local DETECTORS = { "Speed", "Teleport", "Flight", "InfiniteJump", "Acceleration", "Noclip" }
local ALLOWANCE_KINDS = { Teleport = true, Speed = true, Flight = true, Noclip = true, Impulse = true, All = true }

local function flags(default: boolean)
	local fields = {}
	for _, name in DETECTORS do
		fields[name] = S.Boolean(default)
	end
	return S.Table(fields)
end

local CONFIG_SCHEMA = S.Table({
	SampleIntervalSeconds = S.Number(0.2, { Min = 0.05, Max = 2 }),
	MinAllowedSpeed = S.Number(8, { Min = 0, Max = 1000 }),
	SpeedTolerance = S.Number(1.25, { Min = 1, Max = 10 }),
	SpeedSlackStuds = S.Number(4, { Min = 0, Max = 1000 }),
	MinWindowSeconds = S.Number(0.5, { Min = 0.1, Max = 10 }),
	MaxWindowSeconds = S.Number(2, { Min = 0.2, Max = 30 }),
	MaxPingCompensationSeconds = S.Number(0.5, { Min = 0, Max = 5 }),
	TeleportSlackStuds = S.Number(10, { Min = 0, Max = 10000 }),
	TeleportMinDistance = S.Number(20, { Min = 1, Max = 100000 }),
	VerticalSlackStuds = S.Number(8, { Min = 0, Max = 10000 }),
	MaxVerticalPlatformSpeed = S.Number(25, { Min = 0, Max = 10000 }),
	AirborneClearance = S.Number(1.5, { Min = 0, Max = 100 }),
	MaxAirtimeExtraSeconds = S.Number(1, { Min = 0, Max = 60 }),
	MinFallStudsPerSecond = S.Number(4, { Min = 0, Max = 1000 }),
	MaxAirJumps = S.Number(0, { Min = 0, Max = 100, Integer = true }),
	AirJumpRiseStuds = S.Number(3, { Min = 0.5, Max = 1000 }),
	MaxHorizontalAcceleration = S.Number(600, { Min = 1, Max = 100000 }),
	NoclipMinDistance = S.Number(1, { Min = 0.1, Max = 1000 }),
	NoclipMinThickness = S.Number(0.5, { Min = 0.01, Max = 1000 }),
	Detectors = flags(true),
	Severity = S.Table({
		Speed = S.Number(20, { Min = 0, Max = 100 }),
		Teleport = S.Number(30, { Min = 0, Max = 100 }),
		Flight = S.Number(30, { Min = 0, Max = 100 }),
		InfiniteJump = S.Number(25, { Min = 0, Max = 100 }),
		Acceleration = S.Number(10, { Min = 0, Max = 100 }),
		Noclip = S.Number(30, { Min = 0, Max = 100 }),
	}),
	Violation = S.Table({
		HalfLifeSeconds = S.Number(10, { Min = 0.5, Max = 3600 }),
		ReportThreshold = S.Number(5, { Min = 0.1, Max = 10000 }),
		ReportIntervalSeconds = S.Number(10, { Min = 0, Max = 3600 }),
		ConfidenceScale = S.Number(8, { Min = 0.1, Max = 10000 }),
	}),
})

type SessionState = {
	detectors: MovementDetectors.State,
	tracker: ViolationTracker.ViolationTracker,
	allowances: { [string]: number },
	speedMultiplier: { untilTime: number, value: number }?,
	paused: boolean,
	-- Last grounded position with no violations: the correction anchor (Phase 7).
	lastGood: { X: number, Y: number, Z: number, Generation: number }?,
}

-- Violations that server-side correction may undo.
local CORRECTABLE = { Speed = true, Teleport = true, Flight = true, Noclip = true }

local Movement = {}
Movement.Name = MODULE_NAME
Movement.ConfigSchema = CONFIG_SCHEMA

function Movement.new()
	local module: any = {
		Name = MODULE_NAME,
		Version = "1.0.0",
		Category = "Movement",
		EnabledByDefault = true,
		ConfigSchema = CONFIG_SCHEMA,
	}

	local context: any = nil
	local sampleTopic: string? = nil
	local stats = { Samples = 0, Violations = {} :: { [string]: number }, Reports = 0 }

	local function stateFor(session: any): SessionState
		return session:GetState(STATE_KEY, function()
			return {
				detectors = MovementDetectors.newState(session.CharacterGeneration),
				tracker = ViolationTracker.new(context.Config.Violation),
				allowances = {},
				speedMultiplier = nil,
				paused = false,
				lastGood = nil,
			}
		end)
	end

	local function activeAllowances(state: SessionState, now: number): MovementDetectors.Allowances
		local a = state.allowances
		local all = (a.All or 0) > now
		local multiplier = 1
		local boost = state.speedMultiplier
		-- The boost keeps covering the speed window after it expires, so the window that
		-- still contains the fast samples is not judged at normal speed.
		if boost and boost.untilTime + context.Config.MaxWindowSeconds > now then
			multiplier = boost.value
		end
		if all then
			multiplier = math.max(multiplier, 1e6)
		end
		return {
			Teleport = all or (a.Teleport or 0) > now,
			Flight = all or (a.Flight or 0) > now,
			Noclip = all or (a.Noclip or 0) > now,
			Impulse = all or (a.Impulse or 0) > now,
			SpeedMultiplier = multiplier,
		}
	end

	local function sampleSession(session: any, physics: any, now: number)
		local character = session.Character
		if character == nil then
			return
		end
		local ok, sample = pcall(physics.Sample, physics, character, session.Player)
		if not ok then
			context.Logger:Warn("Character sampling failed", { UserId = session.UserId, Error = tostring(sample) })
			return
		end
		if sample == nil then
			return
		end

		local state = stateFor(session)
		if state.detectors.generation ~= session.CharacterGeneration then
			state.detectors = MovementDetectors.newState(session.CharacterGeneration)
		end
		stats.Samples += 1

		-- Pause (and forget history) while seated or dead; resume fresh afterwards.
		if sample.Seated or sample.Health <= 0 or sample.State == "Dead" then
			state.paused = true
			return
		end
		if state.paused then
			state.paused = false
			state.detectors = MovementDetectors.newState(session.CharacterGeneration)
		end

		local allowances = activeAllowances(state, now)
		local function cast(ox, oy, oz, dx, dy, dz)
			return physics:Cast(ox, oy, oz, dx, dy, dz, character)
		end
		local result = MovementDetectors.evaluate(state.detectors, sample, now, context.Config, allowances, cast)

		for _, violation in result.Violations do
			stats.Violations[violation.Detector] = (stats.Violations[violation.Detector] or 0) + 1
			local report, score, confidence = state.tracker:Record(violation.Detector, violation.Weight, now)
			if report then
				stats.Reports += 1
				local details = table.clone(violation.Details)
				details.Score = math.floor(score * 100) / 100
				details.Generation = session.CharacterGeneration
				context:Report(session, {
					Kind = violation.Kind,
					Severity = context.Config.Severity[violation.Detector],
					Confidence = confidence,
					Details = details,
				})
			end
		end

		-- Enforcement level 3 (Phase 7): rubber-band a Movement-restricted player to the
		-- last grounded position that produced no violation. Rate-limited and distance-
		-- capped by Enforcement.Correction; the correction itself is authorised so it is
		-- never scored as a teleport.
		local anchor = state.lastGood
		if #result.Violations == 0 then
			if sample.GroundClearance <= 0.5 then
				state.lastGood = { X = sample.X, Y = sample.Y, Z = sample.Z, Generation = session.CharacterGeneration }
			end
		elseif anchor and anchor.Generation == session.CharacterGeneration and physics.Correct then
			local correctable = false
			for _, violation in result.Violations do
				if CORRECTABLE[violation.Detector] then
					correctable = true
					break
				end
			end
			local distance = math.sqrt((sample.X - anchor.X) ^ 2 + (sample.Y - anchor.Y) ^ 2 + (sample.Z - anchor.Z) ^ 2)
			if
				correctable
				and distance <= context:GetConfig("Enforcement.Correction.MaxDistance")
				and context.Enforcement:ShouldCorrect(session)
			then
				local corrected, problem = pcall(physics.Correct, physics, character, anchor.X, anchor.Y, anchor.Z)
				if corrected then
					state.allowances.Teleport = math.max(state.allowances.Teleport or 0, now + 1)
					state.detectors = MovementDetectors.newState(session.CharacterGeneration)
					context.Enforcement:NoteCorrected(session, {
						Distance = math.floor(distance * 10) / 10,
						Violations = #result.Violations,
					})
				else
					context.Logger:Warn("Movement correction failed", { UserId = session.UserId, Error = tostring(problem) })
				end
			end
		end

		if sampleTopic then
			context.Events:Publish(sampleTopic, {
				Session = session,
				Sample = sample,
				Time = now,
				ObservedSpeed = result.ObservedSpeed,
				AllowedSpeed = result.AllowedSpeed,
				Airborne = result.Airborne,
				Allowances = allowances,
			})
		end
	end

	local function tick(now: number)
		local physics = context.Platform.Physics
		for _, session in context.Players:GetSessions() do
			sampleSession(session, physics, now)
		end
	end

	-- Public surface ------------------------------------------------------------------

	-- Grants a temporary movement allowance for game mechanics.
	-- kind: "Teleport" | "Speed" | "Flight" | "Noclip" | "Impulse" | "All".
	-- For "Speed", options.Multiplier scales the allowed speed (default 2).
	function module:Allow(target: any, kind: string, seconds: number, options: { Multiplier: number? }?)
		if context == nil then
			error("ACF Movement: Allow requires ACF to be started", 2)
		end
		if not ALLOWANCE_KINDS[kind] then
			error(`ACF Movement: unknown allowance kind '{tostring(kind)}'`, 2)
		end
		if type(seconds) ~= "number" or seconds <= 0 or seconds ~= seconds or seconds > 3600 then
			error("ACF Movement: seconds must be a number in (0, 3600]", 2)
		end
		local session = context.Players:GetSession(target)
		if session == nil then
			return false
		end
		local state = stateFor(session)
		local untilTime = context.Clock.Now() + seconds
		if kind == "Speed" then
			local multiplier = (options and options.Multiplier) or 2
			if type(multiplier) ~= "number" or multiplier < 1 or multiplier ~= multiplier then
				error("ACF Movement: Multiplier must be >= 1", 2)
			end
			state.speedMultiplier = { untilTime = untilTime, value = multiplier }
		else
			state.allowances[kind] = math.max(state.allowances[kind] or 0, untilTime)
		end
		return true
	end

	-- Call right before moving a character on the server (PivotTo, spawn points, portals).
	function module:AuthorizeTeleport(target: any, seconds: number?)
		return self:Allow(target, "Teleport", seconds or 1)
	end

	function module:GetStats(): { [string]: any }
		return { Samples = stats.Samples, Violations = table.clone(stats.Violations), Reports = stats.Reports }
	end

	-- Lifecycle -----------------------------------------------------------------------

	function module:Initialize(ctx)
		context = ctx
		if ctx.Config.MaxWindowSeconds <= ctx.Config.MinWindowSeconds then
			error("ModuleSettings.Movement.MaxWindowSeconds must be greater than MinWindowSeconds")
		end
		sampleTopic = ctx.Events:Declare("Sample")
	end

	function module:Start()
		if context.Platform.Physics == nil then
			error("Movement requires Environment.Physics (character sampling)")
		end
		context.Scheduler:Every("Sample", context.Config.SampleIntervalSeconds, tick)
	end

	function module:Stop() end

	function module:Destroy()
		context = nil
	end

	return module
end

return Movement
