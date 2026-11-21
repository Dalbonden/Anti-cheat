--!strict
--[[
	Example client half of StaffCommands.server.luau: shows ACF staff replies as system
	messages in chat. It only listens; it sends nothing to the server.
	(Inside the test place this sits in ServerStorage, where it does not run. In a game,
	put it in StarterPlayerScripts.)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local reply = ReplicatedStorage:WaitForChild("ACFStaffReply") :: RemoteEvent

reply.OnClientEvent:Connect(function(text: string)
	local channels = TextChatService:FindFirstChild("TextChannels")
	local general = channels and channels:FindFirstChild("RBXGeneral")
	if general and general:IsA("TextChannel") then
		general:DisplaySystemMessage(text)
	else
		print("[ACF] " .. text)
	end
end)
