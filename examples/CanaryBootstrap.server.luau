--[[
	Example: rolling out a canary build of ACF (see RELEASING.md).

	Roblox runs one copy of your code in every server, so a canary is the new build
	published everywhere with its enforcement held back:

	  1. Publish the canary build with ENFORCE_PERCENT = 0. Every server runs the new
	     detection, risk and enforcement logic in shadow mode: decisions are made and
	     audited, nothing automatic is applied.
	  2. Review the audit log (ACF:OnEnforcementAudit, shipped to your own storage) and
	     the evaluation criteria in RELEASING.md for a few days.
	  3. Raise ENFORCE_PERCENT step by step (10, 50, 100). Servers are chosen by a hash of
	     game.JobId, so a server keeps its choice for its whole life.
	  4. Promote the same commit to stable with tools/release.sh stable.

	Staff actions (Kick, Ban, case approvals) work in shadow mode too.
]]

local ServerScriptService = game:GetService("ServerScriptService")

-- Share of servers that enforce automatically (0-100).
local ENFORCE_PERCENT = 0

-- Stable 0-99 bucket for this server.
local function serverBucket(jobId: string): number
	local hash = 0
	for index = 1, #jobId do
		hash = (hash * 31 + string.byte(jobId, index)) % 1000003
	end
	return hash % 100
end

local enforcing = serverBucket(game.JobId) < ENFORCE_PERCENT

local ACF = require(ServerScriptService:WaitForChild("ACF"))
ACF:Initialize({
	Enforcement = {
		ShadowMode = not enforcing,
	},
})

ACF:OnEnforcementAudit(function(entry)
	-- Ship to your own storage (DataStore queue, MessagingService, an HTTP log sink...).
	-- Tag entries with the build so canary and stable decisions can be compared.
	local _ = entry
end)

ACF:Start()
print(`[ACF] {ACF.Version} ({ACF.Channel}) started; automatic enforcement {if enforcing then "ON" else "shadow"}`)
