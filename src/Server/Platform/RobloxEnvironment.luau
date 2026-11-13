--!strict
--[[
	Builds the production Environment from real Roblox services.

	This is the only place ACF's core reaches for Players, RunService and HttpService.
	Everything else receives these through the Environment, which is what makes the core
	testable outside Roblox with fakes.
]]

local Types = require(script.Parent.Parent.Types)

local RobloxEnvironment = {}

function RobloxEnvironment.create(): Types.Environment
	local RunService = game:GetService("RunService")
	if not RunService:IsServer() then
		error("ACF can only run on the server", 2)
	end
	local Players = game:GetService("Players")
	local HttpService = game:GetService("HttpService")

	return {
		Players = Players,
		Heartbeat = RunService.Heartbeat,
		Clock = {
			Now = os.clock,
			Wall = function(): number
				return DateTime.now().UnixTimestampMillis / 1000
			end,
		},
		GenerateId = function(): string
			return HttpService:GenerateGUID(false)
		end,
		LogSink = nil,
	}
end

return RobloxEnvironment
