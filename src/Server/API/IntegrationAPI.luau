--!strict
--[[
	Integration API: how a game defines its own rules for ACF to enforce (combat
	weapons and providers; behavioural signals and actions). PublicAPI
	assigns these functions onto the ACF table explicitly, so they are visible to the
	type checker in games that use --!strict. See docs/COMBAT.md.

		ACF:DefineWeapon("Rifle", { Kind = "Hitscan", Damage = 25, FireRate = 10, MaxRange = 400,
			HeadshotMultiplier = 2, Ammo = { Magazine = 30, Reserve = 120, ReloadSeconds = 2 } })
		ACF:SetCombatProvider("CanDamage", function(attacker, target) ... end)

		local result = ACF:ValidateAttack(player, "Rifle", claim)
		if result.Allowed and result.Target and result.Target.Humanoid then
			result.Target.Humanoid:TakeDamage(result.Damage)
		end
]]

local IntegrationAPI = {}

-- Builds the integration methods bound to `getFramework` (returns the singleton).
-- Each function takes the ACF table as its first argument (method-call syntax).
function IntegrationAPI.create(getFramework: () -> any)
	local function combat(requireRunning: boolean): any
		local framework = getFramework()
		if framework:GetState() == "Created" then
			error("ACF: call ACF:Initialize before using the combat API", 3)
		end
		local state = framework:GetModuleState("Combat")
		if state == "Disabled" or framework:GetConfig("Modules").Combat == false then
			error("ACF: the Combat module is disabled (Modules.Combat = false)", 3)
		end
		if requireRunning and state ~= "Running" then
			error("ACF: the Combat module is not running (call ACF:Start)", 3)
		end
		return framework:GetModule("Combat")
	end

	local function behavioral(requireRunning: boolean): any
		local framework = getFramework()
		if framework:GetState() == "Created" then
			error("ACF: call ACF:Initialize before using the behavioural API", 3)
		end
		local state = framework:GetModuleState("Behavioral")
		if state == "Disabled" or framework:GetConfig("Modules").Behavioral == false then
			error("ACF: the Behavioral module is disabled (Modules.Behavioral = false)", 3)
		end
		if requireRunning and state ~= "Running" then
			error("ACF: the Behavioral module is not running (call ACF:Start)", 3)
		end
		return framework:GetModule("Behavioral")
	end

	local api = {}

	-- Declares a weapon or ability. Allowed any time after Initialize; ids are unique.
	function api.DefineWeapon(_self: any, id: string, definition: { [string]: any })
		combat(false):Define(id, definition)
	end

	-- Abilities are weapons with Kind = "Ability"; this sets it for you.
	function api.DefineAbility(_self: any, id: string, definition: { [string]: any })
		local copy = table.clone(definition)
		copy.Kind = "Ability"
		combat(false):Define(id, copy)
	end

	-- "Inventory" | "CanDamage" | "DamageCalculator"; nil restores the default.
	function api.SetCombatProvider(_self: any, name: string, fn: ((...any) -> any)?)
		combat(false):SetProvider(name, fn)
	end

	function api.ValidateAttack(_self: any, player: Player, weaponId: string, claim: { [string]: any }): { [string]: any }
		return combat(true):ValidateAttack(player, weaponId, claim)
	end

	function api.FireProjectile(_self: any, player: Player, weaponId: string, claim: { [string]: any }): { [string]: any }
		return combat(true):FireProjectile(player, weaponId, claim)
	end

	function api.ValidateProjectileHit(_self: any, player: Player, shotId: string, claim: { [string]: any }): { [string]: any }
		return combat(true):ValidateProjectileHit(player, shotId, claim)
	end

	function api.Reload(_self: any, player: Player, weaponId: string): (boolean, string?)
		return combat(true):Reload(player, weaponId)
	end

	function api.GetAmmo(_self: any, player: Player, weaponId: string): (number?, number?, boolean)
		return combat(true):GetAmmo(player, weaponId)
	end

	function api.SetAmmo(_self: any, player: Player, weaponId: string, magazine: number, reserve: number?): boolean
		return combat(true):SetAmmo(player, weaponId, magazine, reserve)
	end

	function api.GetCombatStats(_self: any): { [string]: any }
		return combat(false):GetStats()
	end

	-- Behavioural signals and actions (docs/BEHAVIORAL.md) ---------------------------

	-- Declares a per-player rate to watch, e.g. "Coins". options: { MaxPerSecond?,
	-- Baseline? = { Mean, StdDev } (per second), MinStdDev?, Statistical? }.
	function api.DefineSignal(_self: any, name: string, options: { [string]: any }?)
		behavioral(false):DefineSignal(name, options)
	end

	-- Adds `amount` to a player's signal. Call it where the server grants the resource.
	function api.RecordSignal(_self: any, player: Player, name: string, amount: number): boolean
		return behavioral(true):RecordSignal(player, name, amount)
	end

	-- Records one game action; valid = false for an action the game's client never sends.
	function api.RecordAction(_self: any, player: Player, action: string, valid: boolean?): boolean
		return behavioral(true):RecordAction(player, action, valid)
	end

	function api.GetBehaviorProfile(_self: any, player: Player): { [string]: any }?
		return behavioral(false):GetProfile(player)
	end

	function api.GetBehaviorStats(_self: any): { [string]: any }
		return behavioral(false):GetStats()
	end

	return api
end

return IntegrationAPI
