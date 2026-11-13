--!strict
--[[
	Physics: character physics-state validation (built-in, Category "Physics").

	Consumes Movement's samples (Dependencies = { "Movement" }) and checks:

	  Fling             root angular speed above MaxAngularSpeed. Fling exploits spin the
	                    character root at extreme rates to launch other players.
	  ExtremeVelocity   horizontal or upward linear speed above the configured limits.
	                    Downward speed is ignored: long falls are legitimate.
	  VelocityMismatch  observed displacement speed far above the reported velocity
	                    (CFrame "tp-walk"), only when observed speed also approaches or
	                    exceeds the allowed speed. It corroborates Speed violations.

	All three are suppressed by an "Impulse" or "All" movement allowance (knockback,
	explosions, launch pads) and by teleport allowances, and feed a per-player
	ViolationTracker like every other detector.
]]

local Configuration = require(script.Parent.Parent.Parent.Core.Configuration)
local ViolationTracker = require(script.Parent.Parent.Parent.Intelligence.ViolationTracker)

local S = Configuration.Schema

local MODULE_NAME = "Physics"
local STATE_KEY = "Physics.State"

local CONFIG_SCHEMA = S.Table({
	MaxAngularSpeed = S.Number(60, { Min = 1, Max = 1e9 }),
	MaxHorizontalSpeed = S.Number(300, { Min = 1, Max = 1e9 }),
	MaxUpwardSpeed = S.Number(250, { Min = 1, Max = 1e9 }),
	MismatchRatio = S.Number(2.5, { Min = 1, Max = 1000 }),
	MismatchSlack = S.Number(8, { Min = 0, Max = 10000 }),
	MismatchMinFractionOfAllowed = S.Number(0.8, { Min = 0, Max = 10 }),
	Detectors = S.Table({
		Fling = S.Boolean(true),
		ExtremeVelocity = S.Boolean(true),
		VelocityMismatch = S.Boolean(true),
	}),
	Severity = S.Table({
		Fling = S.Number(35, { Min = 0, Max = 100 }),
		ExtremeVelocity = S.Number(25, { Min = 0, Max = 100 }),
		VelocityMismatch = S.Number(10, { Min = 0, Max = 100 }),
	}),
	Violation = S.Table({
		HalfLifeSeconds = S.Number(10, { Min = 0.5, Max = 3600 }),
		ReportThreshold = S.Number(4, { Min = 0.1, Max = 10000 }),
		ReportIntervalSeconds = S.Number(10, { Min = 0, Max = 3600 }),
		ConfidenceScale = S.Number(8, { Min = 0.1, Max = 10000 }),
	}),
})

local Physics = {}
Physics.Name = MODULE_NAME
Physics.ConfigSchema = CONFIG_SCHEMA

local function round(value: number): number
	return math.floor(value * 100 + 0.5) / 100
end

function Physics.new()
	local module: any = {
		Name = MODULE_NAME,
		Version = "1.0.0",
		Category = "Physics",
		Dependencies = { "Movement" },
		EnabledByDefault = true,
		ConfigSchema = CONFIG_SCHEMA,
	}

	local context: any = nil
	local stats = { Violations = {} :: { [string]: number }, Reports = 0 }

	local function record(session: any, detector: string, kind: string, weight: number, now: number, details: { [string]: any })
		stats.Violations[detector] = (stats.Violations[detector] or 0) + 1
		local tracker = session:GetState(STATE_KEY, function()
			return ViolationTracker.new(context.Config.Violation)
		end)
		local report, score, confidence = tracker:Record(detector, weight, now)
		if report then
			stats.Reports += 1
			details.Score = round(score)
			context:Report(session, {
				Kind = kind,
				Severity = context.Config.Severity[detector],
				Confidence = confidence,
				Details = details,
			})
		end
	end

	local function onSample(payload: any)
		local allowances = payload.Allowances
		if allowances.Impulse or allowances.Teleport then
			return
		end
		local config = context.Config
		local enabled = config.Detectors
		local sample = payload.Sample
		local session = payload.Session
		local now = payload.Time

		if enabled.Fling and sample.AngularSpeed > config.MaxAngularSpeed then
			record(session, "Fling", "FlingDetected", 2, now, {
				AngularSpeed = round(sample.AngularSpeed),
				Limit = config.MaxAngularSpeed,
			})
		end

		local horizontalSpeed = math.sqrt(sample.VX * sample.VX + sample.VZ * sample.VZ)
		if enabled.ExtremeVelocity then
			if horizontalSpeed > config.MaxHorizontalSpeed * allowances.SpeedMultiplier then
				record(session, "ExtremeVelocity", "ExtremeVelocity", 2, now, {
					Axis = "Horizontal",
					Speed = round(horizontalSpeed),
					Limit = config.MaxHorizontalSpeed,
				})
			elseif sample.VY > config.MaxUpwardSpeed then
				record(session, "ExtremeVelocity", "ExtremeVelocity", 2, now, {
					Axis = "Upward",
					Speed = round(sample.VY),
					Limit = config.MaxUpwardSpeed,
				})
			end
		end

		if enabled.VelocityMismatch then
			local observed = payload.ObservedSpeed
			local relevant = observed >= payload.AllowedSpeed * config.MismatchMinFractionOfAllowed
			if relevant and observed > horizontalSpeed * config.MismatchRatio + config.MismatchSlack then
				record(session, "VelocityMismatch", "VelocityMismatch", 1, now, {
					ObservedSpeed = round(observed),
					ReportedSpeed = round(horizontalSpeed),
				})
			end
		end
	end

	function module:GetStats(): { [string]: any }
		return { Violations = table.clone(stats.Violations), Reports = stats.Reports }
	end

	function module:Initialize(ctx)
		context = ctx
	end

	function module:Start()
		context.Events:Subscribe("Movement.Sample", onSample)
	end

	function module:Stop() end

	function module:Destroy()
		context = nil
	end

	return module
end

return Physics
