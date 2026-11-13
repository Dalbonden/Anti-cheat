--!strict
--[[
	Reusable permission and ownership checks for protected remotes.

	A check is a function(player, ...args) -> (allowed: boolean, reason: string?). It
	runs after argument validation, so it can rely on argument types. Checks that throw
	are treated as a denial (fail closed). Checks may yield (e.g. GetRankInGroup).

	Permission = "may this player use this remote at all / with these arguments?"
	Ownership  = "does this player own the object the request refers to?"
	They behave identically but are tracked as separate rejection reasons, because an
	ownership violation (acting on someone else's object) is the stronger signal.
]]

export type Check = (player: any, ...any) -> (boolean, string?)

local Permissions = {}
local Ownership = {}

-- Allows only the listed UserIds.
function Permissions.userIds(list: { number }): Check
	local allowed = {}
	for _, id in list do
		allowed[id] = true
	end
	return function(player)
		return allowed[player.UserId] == true, "user not allowed"
	end
end

-- Allows players whose rank in groupId is at least minRank.
function Permissions.groupRank(groupId: number, minRank: number): Check
	return function(player)
		local ok, rank = pcall(function()
			return player:GetRankInGroup(groupId)
		end)
		if not ok or type(rank) ~= "number" then
			return false, "group rank unavailable"
		end
		return rank >= minRank, "group rank too low"
	end
end

-- Passes when every check passes. Reports the first failing reason.
function Permissions.all(...: Check): Check
	local checks = { ... }
	return function(player, ...)
		for _, check in checks do
			local allowed, reason = check(player, ...)
			if not allowed then
				return false, reason
			end
		end
		return true
	end
end

-- Passes when any check passes.
function Permissions.any(...: Check): Check
	local checks = { ... }
	return function(player, ...)
		local lastReason = nil
		for _, check in checks do
			local allowed, reason = check(player, ...)
			if allowed then
				return true
			end
			lastReason = reason
		end
		return false, lastReason
	end
end

local function argument(index: number, ...: any): any
	return (select(index, ...))
end

-- The Instance at argument `index` must be inside the player's current character.
function Ownership.descendantOfCharacter(index: number): Check
	return function(player, ...)
		local target = argument(index, ...)
		local character = player.Character
		if character == nil or typeof(target) ~= "Instance" then
			return false, "no character"
		end
		return target == character or target:IsDescendantOf(character), "not part of the player's character"
	end
end

-- The Instance at argument `index` must be inside getRoot(player), e.g. the player's plot.
function Ownership.descendantOf(index: number, getRoot: (player: any) -> any): Check
	return function(player, ...)
		local target = argument(index, ...)
		local root = getRoot(player)
		if root == nil or typeof(target) ~= "Instance" then
			return false, "no owned container"
		end
		return target:IsDescendantOf(root), "outside the player's container"
	end
end

-- The Instance at argument `index` (or an ancestor) must carry attribute `name` equal
-- to the player's UserId. Searches at most `maxDepth` ancestors (default 8).
function Ownership.attribute(index: number, name: string, maxDepth: number?): Check
	local depth = maxDepth or 8
	return function(player, ...)
		local target = argument(index, ...)
		if typeof(target) ~= "Instance" then
			return false, "not an Instance"
		end
		local node: Instance? = target
		for _ = 0, depth do
			if not node then
				break
			end
			local owner = node:GetAttribute(name)
			if owner ~= nil then
				return owner == player.UserId, "owned by someone else"
			end
			node = node.Parent
		end
		return false, "no owner attribute"
	end
end

return table.freeze({
	Permissions = table.freeze(Permissions),
	Ownership = table.freeze(Ownership),
})
