--!strict
--[[
	Example: keep ACF's enforcement audit log beyond one server, for the canary review
	(RELEASING.md) and for appeals.

	Entries are buffered and written in batches, one DataStore key per batch:
	  DataStore "ACF_Audit_v1", scope = UTC date ("2026-11-21"),
	  key = "<JobId>/<batch>", value = { Version = 1, Build = ACF.Version, Channel, Entries = {...} }

	Batches flush every FLUSH_SECONDS or at MAX_BATCH entries, with retries, and once more
	at shutdown. Read them with Open Cloud (List Entries by scope) or your own tooling.
	Uses DataStore budget: about one write per minute per server.
	(Inside the test place this sits in ServerStorage, where it does not run.)
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ServerScriptService = game:GetService("ServerScriptService")

local ACF = require(ServerScriptService:WaitForChild("ACF"))

-- Script order is not guaranteed: wait for your bootstrap to call ACF:Initialize.
while ACF:GetStatus().State == "Created" do
	task.wait()
end

local FLUSH_SECONDS = 60
local MAX_BATCH = 200
local MAX_ATTEMPTS = 3

-- GetDataStore throws where DataStores are unavailable (an unpublished place, or Studio
-- without API access). Audit then stays in ACF's in-memory log only.
local opened, store = pcall(function()
	return DataStoreService:GetDataStore("ACF_Audit_v1", os.date("!%Y-%m-%d") :: string)
end)
if not opened then
	warn(`[ACF audit] DataStore unavailable, audit is not persisted: {store}`)
	return
end
local serverId = if game.JobId ~= "" then game.JobId else "studio-" .. HttpService:GenerateGUID(false)
local buffer: { { [string]: any } } = {}
local batch = 0

local function flush()
	if #buffer == 0 then
		return
	end
	local entries = buffer
	buffer = {}
	batch += 1
	local key = `{serverId}/{batch}`
	local value = { Version = 1, Build = ACF.Version, Channel = ACF.Channel, Entries = entries }
	for attempt = 1, MAX_ATTEMPTS do
		local ok, err = pcall(function()
			store:SetAsync(key, value)
		end)
		if ok then
			return
		end
		warn(`[ACF audit] write {key} failed (attempt {attempt}): {err}`)
		task.wait(2 * attempt)
	end
end

ACF:OnEnforcementAudit(function(entry)
	-- Entries are frozen tables of plain values; copy so the batch owns them.
	table.insert(buffer, table.clone(entry))
	if #buffer >= MAX_BATCH then
		task.spawn(flush)
	end
end)

task.spawn(function()
	while true do
		task.wait(FLUSH_SECONDS)
		flush()
	end
end)

game:BindToClose(flush)
