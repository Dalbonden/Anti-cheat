--!strict
--[[
	ACF client telemetry (optional). Sends a heartbeat with a sequence number and the
	measured frame rate every TELEMETRY_INTERVAL_SECONDS.

	This script is NOT a security boundary: an exploiter can delete it or fire the remote
	themselves. The server treats it as a weak hint (see docs/MOVEMENT.md, Telemetry).
	If the server has Telemetry disabled, the remote never appears and the script exits.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Protocol = require(ReplicatedStorage:WaitForChild("ACFShared"):WaitForChild("Protocol"))

local folder = ReplicatedStorage:WaitForChild(Protocol.REMOTES_FOLDER, 30)
if folder == nil then
	return
end
local remote = folder:WaitForChild(Protocol.TELEMETRY_REMOTE, 30)
if remote == nil or not remote:IsA("RemoteEvent") then
	return
end
local telemetry = remote :: RemoteEvent

local frames = 0
RunService.RenderStepped:Connect(function()
	frames += 1
end)

local sequence = 0
while true do
	local started = os.clock()
	task.wait(Protocol.TELEMETRY_INTERVAL_SECONDS)
	local elapsed = math.max(os.clock() - started, 1e-3)
	sequence += 1
	local fps = math.clamp(math.floor(frames / elapsed + 0.5), 0, Protocol.MAX_FPS)
	frames = 0
	telemetry:FireServer(sequence, fps)
end
