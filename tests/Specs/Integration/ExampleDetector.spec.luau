local ServerStorage = game:GetService("ServerStorage")
local ACF = game:GetService("ServerScriptService").ACF
local Framework = require(ACF.Core.Framework)
local Configuration = require(ACF.Core.Configuration)
local Detector = require(ServerStorage.ACFExamples.LeaderstatRateDetector)
local Fakes = require(script.Parent.Parent.Fakes)

local function withCoins(player, initial)
	local coins = { Value = initial }
	local stats = {
		FindFirstChild = function(_, name)
			return if name == "Coins" then coins else nil
		end,
	}
	player:SetChild("leaderstats", stats)
	return coins
end

local function boot(settings)
	local fake = Fakes.environment()
	local framework = Framework.new(fake.Env)
	framework:Initialize({ ModuleSettings = { LeaderstatRate = settings or {} } })
	framework:RegisterModule(Detector.new(Configuration.Schema))
	framework:Start()
	return framework, fake
end

local function tick(framework, fake, seconds)
	fake.Clock.Advance(seconds)
	framework:Step()
end

return function(t)
	local expect = t.expect

	t.describe("Example: LeaderstatRateDetector", function()
		t.it("does not flag legitimate income", function()
			local framework, fake = boot({ MaxGainPerSecond = 10, SampleIntervalSeconds = 1 })
			local player = fake.Players:Join(Fakes.player(1))
			local coins = withCoins(player, 0)
			for _ = 1, 10 do
				tick(framework, fake, 1)
				coins.Value += 8
			end
			tick(framework, fake, 1)
			expect(#framework:GetEvidence(player)).toBe(0)
		end)

		t.it("flags a gain rate above the limit with an explanation", function()
			local framework, fake = boot({ MaxGainPerSecond = 10, SampleIntervalSeconds = 1 })
			local player = fake.Players:Join(Fakes.player(1))
			local coins = withCoins(player, 0)
			tick(framework, fake, 1)
			coins.Value += 1000
			tick(framework, fake, 1)
			local records = framework:GetEvidence(player)
			expect(#records).toBe(1)
			expect(records[1].Kind).toBe("StatGainRateExceeded")
			expect(records[1].Category).toBe("Economy")
			expect(records[1].Details.Rate).toBe(1000)
			expect(records[1].Confidence).toBe(0.9)
		end)

		t.it("ignores spending", function()
			local framework, fake = boot({ MaxGainPerSecond = 10, SampleIntervalSeconds = 1 })
			local player = fake.Players:Join(Fakes.player(1))
			local coins = withCoins(player, 5000)
			tick(framework, fake, 1)
			coins.Value = 0
			tick(framework, fake, 1)
			expect(#framework:GetEvidence(player)).toBe(0)
		end)

		t.it("ignores players without the stat", function()
			local framework, fake = boot({ SampleIntervalSeconds = 1 })
			local player = fake.Players:Join(Fakes.player(1))
			tick(framework, fake, 1)
			tick(framework, fake, 1)
			expect(#framework:GetEvidence(player)).toBe(0)
		end)

		t.it("rejects invalid detector settings at registration", function()
			local fake = Fakes.environment()
			local framework = Framework.new(fake.Env)
			framework:Initialize({ ModuleSettings = { LeaderstatRate = { SampleIntervalSeconds = 0 } } })
			expect(function()
				framework:RegisterModule(Detector.new(Configuration.Schema))
			end).toThrow("SampleIntervalSeconds")
		end)
	end)
end
