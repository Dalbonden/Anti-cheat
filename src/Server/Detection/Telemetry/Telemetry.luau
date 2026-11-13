--!strict
--[[
	Telemetry: optional client heartbeat (built-in, Category "Integrity", disabled by
	default; enable with Modules = { Telemetry = true } and install the client script).

	The server creates ReplicatedStorage.ACFRemotes.Telemetry and protects it with
	RemoteSecurity (validated arguments, rate limit). Per player it tracks:

	  TelemetryMissing    no heartbeat for MissingAfterSeconds after StartupGraceSeconds.
	                      Typical causes: the client script was deleted, or the client is
	                      frozen. Packet loss and lag also cause it, so weight and maximum
	                      confidence are low.
	  TelemetrySequence   a heartbeat sequence that goes backwards or repeats (replay, or
	                      a second script firing the remote).

	Telemetry is a weak signal by design. An exploiter can fire the remote themselves, so
	a *present* heartbeat proves nothing; only its absence or malformation is evidence.
	FPS is stored for diagnostics and latency context; it is never scored.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Protocol = require(ReplicatedStorage:WaitForChild("ACFShared"):WaitForChild("Protocol"))
local Configuration = require(script.Parent.Parent.Parent.Core.Configuration)
local ViolationTracker = require(script.Parent.Parent.Parent.Intelligence.ViolationTracker)
local Validators = require(script.Parent.Parent.RemoteSecurity.Validators)

local S = Configuration.Schema

local MODULE_NAME = "Telemetry"
local STATE_KEY = "Telemetry.State"

local CONFIG_SCHEMA = S.Table({
	StartupGraceSeconds = S.Number(30, { Min = 0, Max = 3600 }),
	MissingAfterSeconds = S.Number(20, { Min = 1, Max = 3600 }),
	CheckIntervalSeconds = S.Number(5, { Min = 0.5, Max = 3600 }),
	Severity = S.Table({
		Missing = S.Number(5, { Min = 0, Max = 100 }),
		Sequence = S.Number(10, { Min = 0, Max = 100 }),
	}),
	Violation = S.Table({
		HalfLifeSeconds = S.Number(120, { Min = 1, Max = 86400 }),
		ReportThreshold = S.Number(6, { Min = 0.1, Max = 10000 }),
		ReportIntervalSeconds = S.Number(120, { Min = 0, Max = 86400 }),
		ConfidenceScale = S.Number(20, { Min = 0.1, Max = 10000 }),
		MaxConfidence = S.Number(0.5, { Min = 0, Max = 1 }),
	}),
})

type SessionState = {
	lastSequence: number,
	lastHeartbeat: number?,
	fps: number?,
	tracker: ViolationTracker.ViolationTracker,
}

local Telemetry = {}
Telemetry.Name = MODULE_NAME
Telemetry.ConfigSchema = CONFIG_SCHEMA

function Telemetry.new()
	local module: any = {
		Name = MODULE_NAME,
		Version = "1.0.0",
		Category = "Integrity",
		Dependencies = { "RemoteSecurity" },
		EnabledByDefault = false,
		ConfigSchema = CONFIG_SCHEMA,
	}

	local context: any = nil
	local protection: any = nil

	local function stateFor(session: any): SessionState
		return session:GetState(STATE_KEY, function()
			return {
				lastSequence = 0,
				lastHeartbeat = nil,
				fps = nil,
				tracker = ViolationTracker.new(context.Config.Violation),
			}
		end)
	end

	local function violation(session: any, state: SessionState, key: string, kind: string, details: { [string]: any })
		local now = context.Clock.Now()
		local report, score, confidence = state.tracker:Record(key, 1, now)
		if report then
			details.Score = math.floor(score * 100) / 100
			context:Report(session, {
				Kind = kind,
				Severity = context.Config.Severity[key],
				Confidence = confidence,
				Details = details,
			})
		end
	end

	local function onHeartbeat(player: any, sequence: number, fps: number)
		local session = context.Players:GetSession(player)
		if session == nil then
			return
		end
		local state = stateFor(session)
		if sequence <= state.lastSequence then
			violation(session, state, "Sequence", "TelemetrySequence", {
				Received = sequence,
				Expected = state.lastSequence + 1,
			})
			return
		end
		state.lastSequence = sequence
		state.lastHeartbeat = context.Clock.Now()
		state.fps = fps
	end

	local function check(now: number)
		local config = context.Config
		for _, session in context.Players:GetSessions() do
			if now - session.JoinedAt >= config.StartupGraceSeconds then
				local state = stateFor(session)
				local since = state.lastHeartbeat or session.JoinedAt
				if now - since > config.MissingAfterSeconds then
					violation(session, state, "Missing", "TelemetryMissing", {
						SecondsSinceHeartbeat = math.floor(now - since),
						EverReceived = state.lastHeartbeat ~= nil,
					})
				end
			end
		end
	end

	-- Last reported FPS for a player (diagnostics), or nil.
	function module:GetFps(target: any): number?
		if context == nil then
			return nil
		end
		local session = context.Players:GetSession(target)
		if session == nil then
			return nil
		end
		return stateFor(session).fps
	end

	function module:Initialize(ctx)
		context = ctx
	end

	function module:Start()
		local remotes = context.Platform.Remotes
		if remotes == nil then
			error("Telemetry requires Environment.Remotes")
		end
		local remote = remotes:GetOrCreate(Protocol.TELEMETRY_REMOTE, "RemoteEvent")
		local security = context:GetModule("RemoteSecurity")
		if protection == nil then
			protection = security:ProtectEvent(remote, {
				Name = "ACF.Telemetry",
				Arguments = {
					Validators.integer({ Min = 1, Max = 2 ^ 31 }),
					Validators.number({ Min = 0, Max = Protocol.MAX_FPS }),
				},
				-- Allows a little jitter around the protocol interval.
				RateLimit = { Burst = 3, PerSecond = 2 / Protocol.TELEMETRY_INTERVAL_SECONDS },
				Handler = onHeartbeat,
			})
		end
		context.Scheduler:Every("Check", context.Config.CheckIntervalSeconds, check)
	end

	function module:Stop() end

	function module:Destroy()
		if protection then
			protection.Unprotect()
			protection = nil
		end
		context = nil
	end

	return module
end

return Telemetry
