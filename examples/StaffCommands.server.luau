--!strict
--[[
	Example: in-game staff commands for ACF enforcement (cases, removals, overrides,
	lookups). Pair it with StaffCommandsClient.client.luau, which shows the replies in chat.

	Security:
	  - Commands are a TextChatCommand ("/acf") handled on the SERVER (Triggered fires on
	    the sender and the server only). DeliverMessage = false, so other players never
	    see a staff command. Legacy-chat games fall back to Player.Chatted, where the
	    command IS visible in chat.
	  - Staff are decided on the server: an explicit UserId list and/or a group rank.
	  - Replies go server -> client only (FireClient); OnServerEvent is never connected.
	  - Every action passes By = "<name> (<userId>)", so the audit log names the person.

	Commands ("/acf <command>"):
	  cases                       open cases, newest first
	  case <caseId>               one case with its explanation
	  approve <caseId> [level] [hours]   approve (level 5 kick, 6 temporary ban, 7 permanent)
	  reject <caseId> [note]      reject
	  risk <player>               risk, band, enforcement level, tags
	  kick <player> [reason]
	  ban <player|userId> <hours|perm> [reason]
	  unban <userId> [reason]
	  exempt <player> [minutes]   exempt from automatic enforcement (testers, staff)
	  unexempt <player>

	New cases are announced to every staff member in the server.
	(Inside the test place this sits in ServerStorage, where it does not run.)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TextChatService = game:GetService("TextChatService")

local ACF = require(ServerScriptService:WaitForChild("ACF"))

-- Script order is not guaranteed: wait for your bootstrap to call ACF:Initialize.
while ACF:GetStatus().State == "Created" do
	task.wait()
end

-- Who counts as staff. Fill in one or both.
local STAFF_USER_IDS: { [number]: boolean } = {
	-- [123456789] = true,
}
local STAFF_GROUP_ID = 0 -- 0 disables the group check
local STAFF_MIN_RANK = 200

local PREFIX = "/acf"

local reply = Instance.new("RemoteEvent")
reply.Name = "ACFStaffReply"
reply.Parent = ReplicatedStorage

local staffCache: { [Player]: boolean } = {}

local function isStaff(player: Player): boolean
	local cached = staffCache[player]
	if cached ~= nil then
		return cached
	end
	local staff = STAFF_USER_IDS[player.UserId] == true
	if not staff and STAFF_GROUP_ID ~= 0 then
		local ok, rank = pcall(function()
			return player:GetRankInGroup(STAFF_GROUP_ID)
		end)
		staff = ok and type(rank) == "number" and rank >= STAFF_MIN_RANK
	end
	staffCache[player] = staff
	return staff
end

local function say(player: Player, text: string)
	reply:FireClient(player, string.sub(text, 1, 800))
end

-- A player in this server by (partial) name, or nil.
local function findPlayer(name: string): Player?
	local lower = string.lower(name)
	for _, player in Players:GetPlayers() do
		if string.lower(player.Name) == lower then
			return player
		end
	end
	for _, player in Players:GetPlayers() do
		if string.sub(string.lower(player.Name), 1, #lower) == lower then
			return player
		end
	end
	return nil
end

-- A Player in this server, or a numeric UserId (for offline actions).
local function findTarget(text: string): (Player | number)?
	local userId = tonumber(text)
	if userId then
		return Players:GetPlayerByUserId(userId) or userId
	end
	return findPlayer(text)
end

local function describe(target: Player | number): string
	if typeof(target) == "Instance" then
		return `{(target :: Player).Name} ({(target :: Player).UserId})`
	end
	return `user {target}`
end

local commands: { [string]: (staff: Player, by: string, args: { string }) -> () } = {}

function commands.cases(staff)
	local cases = ACF:GetCases({ Status = "Open" })
	if #cases == 0 then
		say(staff, "No open cases.")
		return
	end
	for index = #cases, math.max(1, #cases - 7), -1 do
		local case = cases[index]
		local proposal = if case.ProposedLevel then ` proposes level {case.ProposedLevel}` else " review"
		say(staff, `{case.CaseId}: user {case.UserId}{proposal}, risk {math.floor(case.Risk)} ({case.Band})`)
	end
end

function commands.case(staff, _, args)
	for _, case in ACF:GetCases() do
		if case.CaseId == args[1] then
			say(staff, `{case.CaseId} [{case.Status}] user {case.UserId}: {case.Reason}`)
			say(staff, case.Explanation)
			return
		end
	end
	say(staff, "No such case.")
end

function commands.approve(staff, by, args)
	local caseId = args[1]
	local level = tonumber(args[2] or "")
	local hours = tonumber(args[3] or "")
	local ok, err = pcall(function()
		ACF:ApproveCase(caseId, { By = by, Level = level, Hours = hours })
	end)
	say(staff, if ok then `Approved {caseId}.` else `Could not approve: {err}`)
end

function commands.reject(staff, by, args)
	local caseId = table.remove(args, 1)
	local ok, err = pcall(function()
		ACF:RejectCase(caseId :: string, { By = by, Note = table.concat(args, " ") })
	end)
	say(staff, if ok then `Rejected {caseId}.` else `Could not reject: {err}`)
end

function commands.risk(staff, _, args)
	local target = findTarget(args[1] or "")
	if target == nil then
		say(staff, "Player not found.")
		return
	end
	local risk = ACF:GetRisk(target)
	local state = ACF:GetEnforcement(target)
	say(staff, `{describe(target)}: risk {math.floor(risk.Risk)} ({risk.Band}), level {state.LevelName}, tags {table.concat(state.Tags, ", ")}`)
	say(staff, risk.Explanation)
end

function commands.kick(staff, by, args)
	local target = findPlayer(table.remove(args, 1) or "")
	if target == nil then
		say(staff, "Player not found in this server.")
		return
	end
	local appeal = ACF:Kick(target, { By = by, Reason = table.concat(args, " ") })
	say(staff, `Kicked {describe(target)} ({appeal}).`)
end

function commands.ban(staff, by, args)
	local target = findTarget(table.remove(args, 1) or "")
	local duration = table.remove(args, 1)
	if target == nil or duration == nil then
		say(staff, "Usage: ban <player|userId> <hours|perm> [reason]")
		return
	end
	local hours = if duration == "perm" then nil else tonumber(duration)
	if duration ~= "perm" and hours == nil then
		say(staff, "Duration must be a number of hours or 'perm'.")
		return
	end
	local appeal = ACF:Ban(target, { By = by, Hours = hours, Reason = table.concat(args, " ") })
	say(staff, `Banned {describe(target)} {if hours then `for {hours} h` else "permanently"} ({appeal}).`)
end

function commands.unban(staff, by, args)
	local userId = tonumber(table.remove(args, 1) or "")
	if userId == nil then
		say(staff, "Usage: unban <userId> [reason]")
		return
	end
	ACF:Unban(userId, { By = by, Reason = table.concat(args, " ") })
	say(staff, `Unbanned user {userId}.`)
end

function commands.exempt(staff, by, args)
	local target = findPlayer(args[1] or "")
	if target == nil then
		say(staff, "Player not found in this server.")
		return
	end
	local minutes = tonumber(args[2] or "")
	ACF:SetEnforcementOverride(target, {
		Exempt = true,
		Seconds = if minutes then minutes * 60 else nil,
		By = by,
		Reason = "staff command",
	})
	say(staff, `{describe(target)} is exempt{if minutes then ` for {minutes} min` else ""}.`)
end

function commands.unexempt(staff, by, args)
	local target = findPlayer(args[1] or "")
	if target == nil then
		say(staff, "Player not found in this server.")
		return
	end
	ACF:ClearEnforcementOverride(target, { By = by })
	say(staff, `{describe(target)} is no longer exempt.`)
end

local function onCommand(player: Player, message: string)
	if string.lower(string.sub(message, 1, #PREFIX)) ~= PREFIX or not isStaff(player) then
		return
	end
	local args = string.split(string.sub(message, #PREFIX + 2), " ")
	local name = string.lower(table.remove(args, 1) or "")
	local command = commands[name]
	if command == nil then
		say(player, "Commands: cases, case, approve, reject, risk, kick, ban, unban, exempt, unexempt")
		return
	end
	local problem = "unknown error"
	local ok = xpcall(command, function(err)
		problem = tostring(err)
	end, player, `{player.Name} ({player.UserId})`, args)
	if not ok then
		say(player, `Error: {problem}`)
	end
end

if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
	local command = Instance.new("TextChatCommand")
	command.Name = "ACFStaffCommand"
	command.PrimaryAlias = PREFIX
	command.Parent = TextChatService
	command.Triggered:Connect(function(source: TextSource, text: string)
		local player = Players:GetPlayerByUserId(source.UserId)
		if player then
			onCommand(player, text)
		end
	end)
else
	local function watch(player: Player)
		player.Chatted:Connect(function(message: string)
			onCommand(player, message)
		end)
	end
	Players.PlayerAdded:Connect(watch)
	for _, player in Players:GetPlayers() do
		watch(player)
	end
end
Players.PlayerRemoving:Connect(function(player: Player)
	staffCache[player] = nil
end)

-- Announce new cases to staff in this server.
ACF:OnEnforcementCase(function(case)
	if case.Status ~= "Open" then
		return
	end
	local proposal = if case.ProposedLevel then `proposes level {case.ProposedLevel}` else "needs review"
	for _, player in Players:GetPlayers() do
		if isStaff(player) then
			say(player, `[ACF] Case {case.CaseId}: user {case.UserId} {proposal} (risk {math.floor(case.Risk)}). "/acf case {case.CaseId}"`)
		end
	end
end)
