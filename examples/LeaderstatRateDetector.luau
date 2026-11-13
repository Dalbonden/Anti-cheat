--!strict
--[[
	Example custom detector: flags implausibly fast growth of a leaderstat.

	Input:  a numeric leaderstat (e.g. leaderstats.Coins), sampled on the server every
	        SampleIntervalSeconds through the ACF scheduler. Clients cannot fake this
	        value: leaderstats are server-owned.
	Model:  gain rate = (value - previous value) / elapsed seconds. A sample whose rate
	        exceeds MaxGainPerSecond is a violation. Spending (negative change) and
	        respawns are ignored.
	Output: a detection with Kind "StatGainRateExceeded". Confidence scales with how far
	        the rate exceeds the limit, capped at 0.9: one sample is never treated as
	        certain.
	Explain: Details carry the observed rate, the limit, the delta and the window.

	This is deliberately simple. Phase 5 adds statistical baselines (EMA, CUSUM) for
	games whose legitimate income is bursty. Use this file as a template for writing
	ACF modules, not as a finished economy detector.

	Usage:
		local ACF = require(ServerScriptService.ACF)
		local Detector = require(path.to.LeaderstatRateDetector)
		ACF:Initialize({
			ModuleSettings = {
				LeaderstatRate = { StatName = "Coins", MaxGainPerSecond = 50 },
			},
		})
		ACF:RegisterModule(Detector.new(ACF.Schema))
		ACF:Start()
]]

local LeaderstatRateDetector = {}

type Sample = { value: number, time: number }

-- `Schema` is ACF.Schema (Configuration.Schema). Passing it in keeps this example
-- free of hard-coded paths into the ACF package.
function LeaderstatRateDetector.new(Schema: any)
	local module = {
		Name = "LeaderstatRate",
		Version = "1.0.0",
		Category = "Economy",
		ConfigSchema = Schema.Table({
			StatName = Schema.String("Coins", { MaxLength = 64 }),
			MaxGainPerSecond = Schema.Number(100, { Min = 0 }),
			SampleIntervalSeconds = Schema.Number(5, { Min = 0.5, Max = 300 }),
			Severity = Schema.Number(15, { Min = 0, Max = 100 }),
		}),
	}

	local context: any = nil

	local function readStat(player: any): number?
		local stats = player:FindFirstChild("leaderstats")
		local stat = stats and stats:FindFirstChild(context.Config.StatName)
		local value = stat and stat.Value
		return if type(value) == "number" then value else nil
	end

	local function sample(now: number)
		local config = context.Config
		for _, session in context.Players:GetSessions() do
			local value = readStat(session.Player)
			local previous: Sample? = session:GetState("LeaderstatRate.Last")
			if value == nil then
				session:ClearState("LeaderstatRate.Last")
				continue
			end
			if previous then
				local elapsed = now - previous.time
				local delta = value - previous.value
				if elapsed > 0 and delta > 0 then
					local rate = delta / elapsed
					if rate > config.MaxGainPerSecond then
						local excess = if config.MaxGainPerSecond > 0 then rate / config.MaxGainPerSecond else math.huge
						context:Report(session, {
							Kind = "StatGainRateExceeded",
							Severity = config.Severity,
							Confidence = math.min(0.9, 0.5 + 0.1 * (excess - 1)),
							Details = {
								Stat = config.StatName,
								Rate = rate,
								Limit = config.MaxGainPerSecond,
								Delta = delta,
								WindowSeconds = elapsed,
							},
						})
					end
				end
			end
			local last = session:GetState("LeaderstatRate.Last", function()
				return {}
			end)
			last.value = value
			last.time = now
		end
	end

	function module:Initialize(ctx)
		context = ctx
	end

	function module:Start()
		context.Scheduler:Every("Sample", context.Config.SampleIntervalSeconds, sample)
	end

	function module:Stop()
		-- The scheduled task is released automatically (acquired during Start).
		for _, session in context.Players:GetSessions() do
			session:ClearState("LeaderstatRate.Last")
		end
	end

	function module:Destroy()
		context = nil
	end

	return module
end

return LeaderstatRateDetector
