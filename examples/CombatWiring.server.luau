--!strict
--[[
	Example: wiring a gun through ACF so the server authorizes every hit.

	Client (LocalScript) sends a claim:
		Fire:FireServer("Rifle", { Origin = muzzle, Target = hitPart, HitPosition = hitPoint })
		Reload:FireServer("Rifle")

	Server (this script) validates the remote arguments with RemoteSecurity, then asks
	Combat whether the shot and hit are legitimate and how much damage to apply.
	(Inside the test place this sits in ServerStorage, where it does not run.)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ACF = require(ServerScriptService:WaitForChild("ACF"))
local V = ACF.Validators

ACF:Initialize({})

ACF:DefineWeapon("Rifle", {
	Kind = "Hitscan",
	Damage = 25,
	HeadshotMultiplier = 2,
	FireRate = 10,
	MaxRange = 400,
	Falloff = { Start = 150, End = 400, MinMultiplier = 0.6 },
	Ammo = { Magazine = 30, Reserve = 120, ReloadSeconds = 2 },
})

-- Teams: no damage to teammates (this is also the default behaviour).
ACF:SetCombatProvider("CanDamage", function(attacker: Player, target)
	local victim = target.Player
	return victim == nil or attacker.Team == nil or victim.Team ~= attacker.Team
end)

local remotes = ReplicatedStorage:WaitForChild("Remotes")

ACF:ProtectEvent(remotes:WaitForChild("Fire"), {
	Arguments = { V.string({ MaxLength = 32 }), ACF.CombatClaim },
	-- Transport-level limit, generous; the weapon's own FireRate is enforced by Combat.
	RateLimit = { Burst = 20, PerSecond = 20 },
	Handler = function(player: Player, weaponId: string, claim)
		local result = ACF:ValidateAttack(player, weaponId, claim)
		if result.Allowed and result.Target and result.Target.Humanoid and result.Damage > 0 then
			result.Target.Humanoid:TakeDamage(result.Damage)
		end
	end,
})

ACF:ProtectEvent(remotes:WaitForChild("Reload"), {
	Arguments = { V.string({ MaxLength = 32 }) },
	RateLimit = { Burst = 3, PerSecond = 1 },
	Handler = function(player: Player, weaponId: string)
		ACF:Reload(player, weaponId)
	end,
})

ACF:Start()
