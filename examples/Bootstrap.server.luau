--!strict
--[[
	Example bootstrap. Copy into ServerScriptService as a Script in your own game and
	adjust. (Inside the test place this sits in ServerStorage, where it does not run.)
]]

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local ACF = require(ServerScriptService:WaitForChild("ACF"))
local LeaderstatRateDetector = require(ServerStorage:WaitForChild("ACFExamples"):WaitForChild("LeaderstatRateDetector"))

ACF:Initialize({
	LogLevel = "Info",
	Enforcement = {
		Mode = "Hybrid",
		AutoKick = true,
		AutoBan = false,
		ShadowMode = true, -- observe only while tuning thresholds
	},
	ModuleSettings = {
		LeaderstatRate = { StatName = "Coins", MaxGainPerSecond = 50 },
	},
})

ACF:RegisterModule(LeaderstatRateDetector.new(ACF.Schema))

ACF:OnDetection(function(payload)
	local event = payload.Event
	print(`[ACF] {event.Detector}/{event.Kind} user={event.UserId} severity={event.Severity} confidence={event.Confidence}`)
end)

ACF:Start()
