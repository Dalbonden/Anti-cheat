--!strict
--[[
	Builds the production Environment from real Roblox services.

	This is the only place ACF's core reaches for Players, RunService and HttpService.
	Everything else receives these through the Environment, which is what makes the core
	testable outside Roblox with fakes.
]]

local Types = require(script.Parent.Parent.Types)
local RobloxPhysics = require(script.Parent.RobloxPhysics)
local RobloxStore = require(script.Parent.RobloxStore)

-- Longest time BindToClose waits for queued saves (Roblox allows 30 s in total).
local SHUTDOWN_WAIT_SECONDS = 25

local RobloxEnvironment = {}

function RobloxEnvironment.create(): Types.Environment
	local RunService = game:GetService("RunService")
	if not RunService:IsServer() then
		error("ACF can only run on the server", 2)
	end
	local Players = game:GetService("Players")
	local HttpService = game:GetService("HttpService")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Protocol = require(ReplicatedStorage:WaitForChild("ACFShared"):WaitForChild("Protocol"))

	local remotes = {}
	function remotes.GetOrCreate(_self: any, name: string, className: string): Instance
		local folder = ReplicatedStorage:FindFirstChild(Protocol.REMOTES_FOLDER)
		if folder == nil then
			folder = Instance.new("Folder")
			folder.Name = Protocol.REMOTES_FOLDER
			folder.Parent = ReplicatedStorage
		end
		local existing = folder:FindFirstChild(name)
		if existing and existing.ClassName == className then
			return existing
		end
		local remote = Instance.new(className)
		remote.Name = name
		remote.Parent = folder
		return remote
	end

	return {
		Players = Players,
		Heartbeat = RunService.Heartbeat,
		Physics = RobloxPhysics.create(),
		Remotes = remotes,
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
		Store = RobloxStore.create(),
		OnShutdown = function(flush: () -> (), pending: () -> number)
			game:BindToClose(function()
				flush()
				local started = os.clock()
				while pending() > 0 and os.clock() - started < SHUTDOWN_WAIT_SECONDS do
					task.wait(0.25)
				end
			end)
		end,
	}
end

return RobloxEnvironment
