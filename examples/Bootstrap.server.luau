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

-- Protect your game's remotes. Rojo users typically keep them in ReplicatedStorage.Remotes.
local V = ACF.Validators
local remotes = game:GetService("ReplicatedStorage"):FindFirstChild("Remotes")
if remotes then
	local buyItem = remotes:FindFirstChild("BuyItem")
	if buyItem and buyItem:IsA("RemoteEvent") then
		ACF:ProtectEvent(buyItem, {
			Arguments = { V.string({ MaxLength = 32 }), V.integer({ Min = 1, Max = 99 }) },
			RateLimit = { Burst = 5, PerSecond = 1 },
			Handler = function(player: Player, itemId: string, quantity: number)
				print(`{player.Name} buys {quantity}x {itemId}`)
			end,
		})
	end
	for _, remote in ACF:FindUnprotectedRemotes(remotes) do
		warn(`[ACF] Unprotected remote: {remote:GetFullName()}`)
	end
end

ACF:OnDetection(function(payload)
	local event = payload.Event
	print(`[ACF] {event.Detector}/{event.Kind} user={event.UserId} severity={event.Severity} confidence={event.Confidence}`)
end)

ACF:Start()
