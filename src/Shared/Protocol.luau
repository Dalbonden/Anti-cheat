--!strict
--[[
	ACF client/server protocol. Replicates to clients: names and intervals only.

	Telemetry heartbeat (client -> server, RemoteEvent):
		ReplicatedStorage[REMOTES_FOLDER][TELEMETRY_REMOTE]:FireServer(sequence: integer, fps: number)
	sequence increases by exactly 1 per heartbeat, starting at 1.

	Everything a client sends is untrusted. The server validates the payload with
	RemoteSecurity and treats telemetry as a weak hint only.
]]

local Protocol = table.freeze({
	REMOTES_FOLDER = "ACFRemotes",
	TELEMETRY_REMOTE = "Telemetry",
	TELEMETRY_INTERVAL_SECONDS = 5,
	MAX_FPS = 1000,
})

return Protocol
