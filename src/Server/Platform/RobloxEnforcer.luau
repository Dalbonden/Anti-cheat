--!strict
--[[
	Roblox implementation of Environment.Enforcer.

	  Kick   Player:Kick(message)
	  Ban    Players:BanAsync (universe-wide; Duration -1 = permanent). Runs in its own
	         thread, pcall-wrapped; the outcome reaches the callback.
	  Unban  Players:UnbanAsync

	ACF's own ban records (DataStore) enforce bans on join whether or not the Roblox ban
	API call succeeds, so a failed BanAsync never lets a banned player back in to a
	server running ACF. Places where the ban API is unavailable (old Studio builds,
	disabled API access) should set Enforcement.Bans.UseRobloxBanApi = false.

	Studio-only code path; verify with the Studio run.
]]

local Types = require(script.Parent.Parent.Types)

local RobloxEnforcer = {}

function RobloxEnforcer.create(): Types.Enforcer
	local Players = game:GetService("Players")
	local enforcer = {}

	function enforcer.Kick(_self: any, player: any, message: string)
		local ok, err = pcall(function()
			(player :: Player):Kick(message)
		end)
		if not ok then
			warn("[ACF] Kick failed: " .. tostring(err))
		end
	end

	function enforcer.Ban(
		_self: any,
		userId: number,
		seconds: number?,
		displayReason: string,
		privateReason: string,
		callback: (boolean, string?) -> ()
	)
		task.spawn(function()
			local ok, err = pcall(function()
				(Players :: any):BanAsync({
					UserIds = { userId },
					ApplyToUniverse = true,
					Duration = seconds or -1,
					DisplayReason = string.sub(displayReason, 1, 400),
					PrivateReason = string.sub(privateReason, 1, 1000),
					ExcludeAltAccounts = false,
				})
			end)
			callback(ok, if ok then nil else tostring(err))
		end)
	end

	function enforcer.Unban(_self: any, userId: number, callback: (boolean, string?) -> ())
		task.spawn(function()
			local ok, err = pcall(function()
				(Players :: any):UnbanAsync({ UserIds = { userId }, ApplyToUniverse = true })
			end)
			callback(ok, if ok then nil else tostring(err))
		end)
	end

	return enforcer :: any
end

return RobloxEnforcer
