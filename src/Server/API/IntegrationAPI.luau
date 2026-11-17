--!strict
--[[
	Integration API: how a game defines its own rules for ACF to enforce. Installed onto
	the public ACF table by PublicAPI. See docs/COMBAT.md.

		ACF:DefineWeapon("Rifle", { Kind = "Hitscan", Damage = 25, FireRate = 10, MaxRange = 400,
			HeadshotMultiplier = 2, Ammo = { Magazine = 30, Reserve = 120, ReloadSeconds = 2 } })
		ACF:SetCombatProvider("CanDamage", function(attacker, target) ... end)

		local result = ACF:ValidateAttack(player, "Rifle", claim)
		if result.Allowed and result.Target and result.Target.Humanoid then
			result.Target.Humanoid:TakeDamage(result.Damage)
		end
]]

local IntegrationAPI = {}

-- Adds the combat integration methods to `ACF`. `getFramework` returns the singleton.
function IntegrationAPI.install(ACF: any, getFramework: () -> any, claimValidator: any)
	local function combat(requireRunning: boolean): any
		local framework = getFramework()
		if framework:GetState() == "Created" then
			error("ACF: call ACF:Initialize before using the combat API", 3)
		end
		local state = framework:GetModuleState("Combat")
		if state == "Disabled" or (framework:GetConfig("Modules").Combat == false) then
			error("ACF: the Combat module is disabled (Modules.Combat = false)", 3)
		end
		if requireRunning and state ~= "Running" then
			error("ACF: the Combat module is not running (call ACF:Start)", 3)
		end
		return framework:GetModule("Combat")
	end

	-- Remote argument validator for attack claims, for use in ProtectEvent Arguments.
	ACF.CombatClaim = claimValidator

	-- Declares a weapon or ability. Allowed any time after Initialize; ids are unique.
	function ACF.DefineWeapon(_self: any, id: string, definition: any)
		combat(false):Define(id, definition)
	end

	-- Abilities are weapons with Kind = "Ability"; this sets it for you.
	function ACF.DefineAbility(_self: any, id: string, definition: any)
		local copy = table.clone(definition)
		copy.Kind = "Ability"
		combat(false):Define(id, copy)
	end

	-- "Inventory" | "CanDamage" | "DamageCalculator"; nil restores the default.
	function ACF.SetCombatProvider(_self: any, name: string, fn: any)
		combat(false):SetProvider(name, fn)
	end

	function ACF.ValidateAttack(_self: any, player: Player, weaponId: string, claim: any)
		return combat(true):ValidateAttack(player, weaponId, claim)
	end

	function ACF.FireProjectile(_self: any, player: Player, weaponId: string, claim: any)
		return combat(true):FireProjectile(player, weaponId, claim)
	end

	function ACF.ValidateProjectileHit(_self: any, player: Player, shotId: string, claim: any)
		return combat(true):ValidateProjectileHit(player, shotId, claim)
	end

	function ACF.Reload(_self: any, player: Player, weaponId: string)
		return combat(true):Reload(player, weaponId)
	end

	function ACF.GetAmmo(_self: any, player: Player, weaponId: string)
		return combat(true):GetAmmo(player, weaponId)
	end

	function ACF.SetAmmo(_self: any, player: Player, weaponId: string, magazine: number, reserve: number?)
		return combat(true):SetAmmo(player, weaponId, magazine, reserve)
	end

	function ACF.GetCombatStats(_self: any)
		return combat(false):GetStats()
	end
end

return IntegrationAPI
