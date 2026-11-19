--!strict
--[[
	Combat: server-authoritative combat integrity (built-in, Category "Combat").

	Games declare weapons and abilities (CombatRules) and route client attack *claims*
	through ValidateAttack / FireProjectile / ValidateProjectileHit. ACF decides whether
	the shot happened and whether the hit is plausible, and computes the damage. The
	client never supplies damage, fire rate, range or ammo.

	Stage 1, shot legitimacy (a passing shot consumes ammo and starts cooldowns):
	  UnknownWeapon, InvalidClaim, ShooterDead, NotOwned, Reloading, NoAmmo, Cooldown,
	  OriginMismatch (claimed origin far from the shooter's server position), FireRate.
	Stage 2, hit legitimacy (the hit is refused; the shot still counted):
	  InvalidClaim, HitMismatch (claimed hit point far from the part), SelfHit,
	  TargetDead, OutOfRange, FriendlyFire, NoLineOfSight, and for projectiles
	  UnknownShot, DuplicateShot, ProjectileExpired, ProjectileTiming (arrived before the
	  projectile could), OffTrajectory.

	Latency: ranges and hit tolerances grow with the shooter's ping x MaxTargetSpeed;
	cooldowns have a small tolerance; fire rate uses a token bucket with a refill margin.

	Every rejection feeds a per-player ViolationTracker with a per-reason weight. One
	desynced shot never reports; sustained impossible combat does. Accuracy and
	reaction-time statistics are Phase 5 (Behavioral), so skill is not judged here.
]]

local Configuration = require(script.Parent.Parent.Parent.Core.Configuration)
local RateLimiter = require(script.Parent.Parent.Parent.Core.RateLimiter)
local ViolationTracker = require(script.Parent.Parent.Parent.Intelligence.ViolationTracker)
local Validators = require(script.Parent.Parent.RemoteSecurity.Validators)
local CombatRules = require(script.Parent.CombatRules)
local Types = require(script.Parent.Parent.Parent.Types)

local S = Configuration.Schema

local MODULE_NAME = "Combat"
local STATE_KEY = "Combat.State"

local REASONS = {
	"UnknownWeapon",
	"InvalidClaim",
	"ShooterDead",
	"NotOwned",
	"Reloading",
	"NoAmmo",
	"Cooldown",
	"OriginMismatch",
	"FireRate",
	"HitMismatch",
	"SelfHit",
	"TargetDead",
	"OutOfRange",
	"FriendlyFire",
	"NoLineOfSight",
	"UnknownShot",
	"DuplicateShot",
	"ProjectileExpired",
	"ProjectileTiming",
	"OffTrajectory",
}

local DEFAULT_WEIGHTS = {
	UnknownWeapon = 3,
	InvalidClaim = 2,
	ShooterDead = 1,
	NotOwned = 3,
	Reloading = 1,
	NoAmmo = 1,
	Cooldown = 1,
	OriginMismatch = 2,
	FireRate = 1.5,
	HitMismatch = 1,
	SelfHit = 0.5,
	TargetDead = 0,
	OutOfRange = 2,
	FriendlyFire = 0.5,
	NoLineOfSight = 1.5,
	UnknownShot = 2,
	DuplicateShot = 2,
	ProjectileExpired = 1,
	ProjectileTiming = 2,
	OffTrajectory = 2,
}

local DEFAULT_SEVERITY = {
	UnknownWeapon = 30,
	InvalidClaim = 20,
	ShooterDead = 15,
	NotOwned = 35,
	Reloading = 10,
	NoAmmo = 15,
	Cooldown = 15,
	OriginMismatch = 30,
	FireRate = 30,
	HitMismatch = 20,
	SelfHit = 5,
	TargetDead = 0,
	OutOfRange = 30,
	FriendlyFire = 5,
	NoLineOfSight = 25,
	UnknownShot = 25,
	DuplicateShot = 25,
	ProjectileExpired = 10,
	ProjectileTiming = 30,
	OffTrajectory = 25,
}

local function reasonTable(defaults: { [string]: number }, max: number)
	local fields = {}
	for _, reason in REASONS do
		fields[reason] = S.Number(defaults[reason], { Min = 0, Max = max })
	end
	return S.Table(fields)
end

local CONFIG_SCHEMA = S.Table({
	OriginToleranceStuds = S.Number(8, { Min = 0, Max = 10000 }),
	RangeToleranceFraction = S.Number(0.1, { Min = 0, Max = 10 }),
	RangeToleranceStuds = S.Number(5, { Min = 0, Max = 10000 }),
	HitToleranceStuds = S.Number(6, { Min = 0, Max = 10000 }),
	MaxTargetSpeed = S.Number(32, { Min = 0, Max = 100000 }),
	MaxPingCompensationSeconds = S.Number(0.5, { Min = 0, Max = 5 }),
	LineOfSightEndToleranceStuds = S.Number(2, { Min = 0, Max = 1000 }),
	CooldownToleranceSeconds = S.Number(0.1, { Min = 0, Max = 60 }),
	FireRateTolerance = S.Number(1.15, { Min = 1, Max = 10 }),
	ProjectileTimingToleranceSeconds = S.Number(0.15, { Min = 0, Max = 10 }),
	ProjectileTrajectoryToleranceStuds = S.Number(6, { Min = 0, Max = 10000 }),
	ProjectileTrajectoryToleranceFraction = S.Number(0.03, { Min = 0, Max = 10 }),
	MaxPendingProjectiles = S.Number(32, { Min = 1, Max = 4096, Integer = true }),
	Weights = reasonTable(DEFAULT_WEIGHTS, 1000),
	Severity = reasonTable(DEFAULT_SEVERITY, 100),
	Violation = S.Table({
		HalfLifeSeconds = S.Number(20, { Min = 0.5, Max = 3600 }),
		ReportThreshold = S.Number(6, { Min = 0.1, Max = 10000 }),
		ReportIntervalSeconds = S.Number(10, { Min = 0, Max = 3600 }),
		ConfidenceScale = S.Number(10, { Min = 0.1, Max = 10000 }),
	}),
})

-- Remote argument validator for attack claims; use in ProtectEvent Arguments.
local CLAIM_VALIDATOR = Validators.struct({
	Origin = Validators.optional(Validators.vector3({ MaxMagnitude = 1e6 })),
	Direction = Validators.optional(Validators.vector3({ MaxMagnitude = 1e6 })),
	Target = Validators.optional(Validators.instance("BasePart")),
	HitPosition = Validators.optional(Validators.vector3({ MaxMagnitude = 1e6 })),
	ShotId = Validators.optional(Validators.string({ MinLength = 1, MaxLength = 64 })),
})

type Definition = CombatRules.Definition

type Projectile = {
	id: string,
	weapon: string,
	t: number,
	ox: number,
	oy: number,
	oz: number,
	dx: number,
	dy: number,
	dz: number,
	pierceLeft: number,
	-- The first character hit is counted for accuracy statistics; pierce hits are not.
	hitCounted: boolean,
}

type WeaponState = {
	limiter: RateLimiter.RateLimiter?,
	lastUse: number?,
	magazine: number,
	reserve: number,
	reloadUntil: number?,
}

type CombatState = {
	tracker: ViolationTracker.ViolationTracker,
	weapons: { [string]: WeaponState },
	projectiles: { [string]: Projectile },
	projectileOrder: { string },
}

export type AttackResult = {
	Allowed: boolean,
	Reason: string?,
	-- true when the shot itself was legitimate (ammo consumed) even if the hit was refused.
	ShotAccepted: boolean,
	Damage: number,
	Headshot: boolean,
	Target: Types.TargetInfo?,
	Distance: number?,
}

export type Claim = {
	Origin: any?,
	Direction: any?,
	Target: any?,
	HitPosition: any?,
	ShotId: string?,
}

local Combat = {}
Combat.Name = MODULE_NAME
Combat.ConfigSchema = CONFIG_SCHEMA
Combat.ClaimValidator = CLAIM_VALIDATOR
Combat.Reasons = table.freeze(table.clone(REASONS))

local function defaultInventory(player: any, weaponId: string, definition: Definition): boolean
	if definition.Kind == "Ability" then
		return true
	end
	local character = player.Character
	if character and character:FindFirstChild(weaponId) then
		return true
	end
	local backpack = player:FindFirstChild("Backpack")
	return backpack ~= nil and backpack:FindFirstChild(weaponId) ~= nil
end

local function defaultCanDamage(attacker: any, target: Types.TargetInfo): boolean
	local victim = target.Player
	if victim == nil then
		return true
	end
	local ok, sameTeam = pcall(function()
		return attacker.Team ~= nil and attacker.Team == victim.Team and not attacker.Neutral
	end)
	return not (ok and sameTeam)
end

local PROVIDERS = { Inventory = true, CanDamage = true, DamageCalculator = true }

local function rejected(reason: string, shotAccepted: boolean): AttackResult
	return { Allowed = false, Reason = reason, ShotAccepted = shotAccepted, Damage = 0, Headshot = false }
end

local function round(value: number): number
	return math.floor(value * 100 + 0.5) / 100
end

function Combat.new()
	local module: any = {
		Name = MODULE_NAME,
		Version = "1.0.0",
		Category = "Combat",
		EnabledByDefault = true,
		ConfigSchema = CONFIG_SCHEMA,
	}

	local context: any = nil
	local running = false
	local definitions: { [string]: Definition } = {}
	local providers: { [string]: any } = {
		Inventory = defaultInventory,
		CanDamage = defaultCanDamage,
		DamageCalculator = nil,
	}
	local stats: { [string]: { Shots: number, Hits: number, Rejected: { [string]: number } } } = {}
	local globalRejected: { [string]: number } = {}
	local shotTopic: string? = nil

	local function combatState(session: any): CombatState
		return session:GetState(STATE_KEY, function()
			return {
				tracker = ViolationTracker.new(context.Config.Violation),
				weapons = {},
				projectiles = {},
				projectileOrder = {},
			}
		end)
	end

	local function finishReload(ws: WeaponState, definition: Definition)
		local ammo = definition.Ammo
		if ammo then
			local take = math.min(ammo.Magazine - ws.magazine, ws.reserve)
			ws.magazine += take
			ws.reserve -= take
		end
		ws.reloadUntil = nil
	end

	local function weaponState(state: CombatState, definition: Definition, now: number): WeaponState
		local ws = state.weapons[definition.Id]
		if ws == nil then
			local ammo = definition.Ammo
			local limiter = nil
			if definition.FireRate then
				limiter = RateLimiter.new(
					definition.Burst,
					definition.FireRate * context.Config.FireRateTolerance,
					context.Clock.Now,
					1
				)
			end
			ws = {
				limiter = limiter,
				lastUse = nil,
				magazine = if ammo then ammo.Magazine else math.huge,
				reserve = if ammo then ammo.Reserve else math.huge,
				reloadUntil = nil,
			}
			state.weapons[definition.Id] = ws
		end
		local reloadUntil = ws.reloadUntil
		if reloadUntil and now >= reloadUntil then
			finishReload(ws, definition)
		end
		return ws
	end

	local function weaponStats(id: string)
		local entry = stats[id]
		if entry == nil then
			entry = { Shots = 0, Hits = 0, Rejected = {} }
			stats[id] = entry
		end
		return entry
	end

	-- Records a rejection, scores it, reports when sustained. Returns the result.
	local function reject(
		session: any?,
		state: CombatState?,
		weaponId: string?,
		reason: string,
		shotAccepted: boolean,
		details: { [string]: any }?
	): AttackResult
		globalRejected[reason] = (globalRejected[reason] or 0) + 1
		if weaponId and definitions[weaponId] then
			local entry = weaponStats(weaponId)
			entry.Rejected[reason] = (entry.Rejected[reason] or 0) + 1
		end
		if session and state then
			local config = context.Config
			local now = context.Clock.Now()
			local report, score, confidence = state.tracker:Record(reason, config.Weights[reason], now)
			if report then
				local reportDetails: { [string]: any } = if details then table.clone(details) else {}
				reportDetails.Weapon = weaponId
				reportDetails.Score = round(score)
				context:Report(session, {
					Kind = "Combat" .. reason,
					Severity = config.Severity[reason],
					Confidence = confidence,
					Details = reportDetails,
				})
			end
		end
		return rejected(reason, shotAccepted)
	end

	local function callProvider(name: string, ...: any): (boolean, any)
		local fn = providers[name]
		if fn == nil then
			return true, nil
		end
		local ok, result = pcall(fn, ...)
		if not ok then
			context.Logger:Error("Combat provider errored; treated as denial", { Provider = name, Error = tostring(result) })
			return false, nil
		end
		return true, result
	end

	local function pingCompensation(sample: any): number
		local ping = sample.Ping
		if type(ping) ~= "number" or ping ~= ping or ping < 0 then
			return 0
		end
		return math.min(ping, context.Config.MaxPingCompensationSeconds)
	end

	type Shooter = { session: any, state: CombatState, definition: Definition, ws: WeaponState, sample: any, ox: number, oy: number, oz: number }

	-- Stage 1. Returns (Shooter, nil) or (nil, rejection).
	local function admitShot(player: any, weaponId: any, claim: any, expectedKind: string?): (Shooter?, AttackResult?)
		if not running then
			return nil, rejected("NotRunning", false)
		end
		local session = context.Players:GetSession(player)
		if session == nil then
			return nil, rejected("NoSession", false)
		end
		local state = combatState(session)
		local definition = if type(weaponId) == "string" then definitions[weaponId] else nil
		if definition == nil then
			return nil, reject(session, state, nil, "UnknownWeapon", false)
		end
		if expectedKind == "Projectile" and definition.Kind ~= "Projectile" then
			return nil, reject(session, state, weaponId, "InvalidClaim", false, { Problem = "not a projectile weapon" })
		elseif expectedKind ~= "Projectile" and definition.Kind == "Projectile" then
			return nil, reject(session, state, weaponId, "InvalidClaim", false, { Problem = "use FireProjectile" })
		end
		if type(claim) ~= "table" then
			return nil, reject(session, state, weaponId, "InvalidClaim", false, { Problem = "claim must be a table" })
		end

		local physics = context.Platform.Physics
		local character = session.Character
		local sample = nil
		if character and physics then
			local ok, result = pcall(physics.Sample, physics, character, session.Player)
			sample = if ok then result else nil
		end
		if sample == nil or sample.Health <= 0 then
			return nil, reject(session, state, weaponId, "ShooterDead", false)
		end

		local owned, result = callProvider("Inventory", player, weaponId, definition)
		if not owned or not result then
			return nil, reject(session, state, weaponId, "NotOwned", false)
		end

		local now = context.Clock.Now()
		local ws = weaponState(state, definition, now)
		if ws.reloadUntil ~= nil then
			return nil, reject(session, state, weaponId, "Reloading", false)
		end
		if definition.Ammo and ws.magazine <= 0 then
			return nil, reject(session, state, weaponId, "NoAmmo", false)
		end
		local config = context.Config
		local lastUse = ws.lastUse
		if definition.Cooldown > 0 and lastUse ~= nil and now - lastUse < definition.Cooldown - config.CooldownToleranceSeconds then
			return nil, reject(session, state, weaponId, "Cooldown", false, {
				SinceLastUse = round(now - lastUse),
				Cooldown = definition.Cooldown,
			})
		end

		local ox, oy, oz = sample.X, sample.Y, sample.Z
		if claim.Origin ~= nil then
			local cx, cy, cz = CombatRules.vector(claim.Origin)
			if cx == nil then
				return nil, reject(session, state, weaponId, "InvalidClaim", false, { Problem = "Origin" })
			end
			local offset = CombatRules.distance(cx :: number, cy :: number, cz :: number, sample.X, sample.Y, sample.Z)
			local allowed = config.OriginToleranceStuds + pingCompensation(sample) * math.max(sample.WalkSpeed, 16) * 1.25
			if offset > allowed then
				return nil, reject(session, state, weaponId, "OriginMismatch", false, {
					Offset = round(offset),
					Allowed = round(allowed),
				})
			end
			ox, oy, oz = cx :: number, cy :: number, cz :: number
		elseif definition.Kind == "Hitscan" or definition.Kind == "Projectile" then
			return nil, reject(session, state, weaponId, "InvalidClaim", false, { Problem = "Origin required" })
		end

		local limiter = ws.limiter
		if limiter and not limiter:Allow("shot") then
			return nil, reject(session, state, weaponId, "FireRate", false, { FireRate = definition.FireRate })
		end

		-- Commit the shot.
		if definition.Ammo then
			ws.magazine -= 1
		end
		ws.lastUse = now
		weaponStats(weaponId).Shots += 1
		return {
			session = session,
			state = state,
			definition = definition,
			ws = ws,
			sample = sample,
			ox = ox,
			oy = oy,
			oz = oz,
		},
			nil
	end

	-- Stage 2. originX.. is where the shot left (validated); rangeFrom.. measures range.
	local function evaluateHit(shooter: Shooter, claim: Claim, checkLineOfSight: boolean): AttackResult
		local session, state, definition = shooter.session, shooter.state, shooter.definition
		local weaponId = definition.Id
		local config = context.Config
		local sample = shooter.sample
		local slack = pingCompensation(sample) * config.MaxTargetSpeed

		local target = claim.Target
		if target == nil then
			if definition.RequireTarget then
				return reject(session, state, weaponId, "InvalidClaim", true, { Problem = "Target required" })
			end
			if claim.HitPosition ~= nil then
				local hx, hy, hz = CombatRules.vector(claim.HitPosition)
				if hx == nil then
					return reject(session, state, weaponId, "InvalidClaim", true, { Problem = "HitPosition" })
				end
				local distance = CombatRules.distance(shooter.ox, shooter.oy, shooter.oz, hx :: number, hy :: number, hz :: number)
				local maxRange = definition.MaxRange * (1 + config.RangeToleranceFraction) + config.RangeToleranceStuds + slack
				if distance > maxRange then
					return reject(session, state, weaponId, "OutOfRange", true, { Distance = round(distance), MaxRange = definition.MaxRange })
				end
				return { Allowed = true, ShotAccepted = true, Damage = 0, Headshot = false, Target = nil, Distance = distance }
			end
			return { Allowed = true, ShotAccepted = true, Damage = 0, Headshot = false, Target = nil }
		end

		local physics = context.Platform.Physics
		local info: Types.TargetInfo? = nil
		if typeof(target) == "Instance" and physics and physics.Describe then
			local ok, result = pcall(physics.Describe, physics, target)
			info = if ok then result else nil
		end
		if info == nil then
			return reject(session, state, weaponId, "InvalidClaim", true, { Problem = "Target is not a hittable part" })
		end
		local targetInfo = info :: Types.TargetInfo

		local hx, hy, hz = targetInfo.X, targetInfo.Y, targetInfo.Z
		if claim.HitPosition ~= nil then
			local cx, cy, cz = CombatRules.vector(claim.HitPosition)
			if cx == nil then
				return reject(session, state, weaponId, "InvalidClaim", true, { Problem = "HitPosition" })
			end
			local mismatch = CombatRules.distance(cx :: number, cy :: number, cz :: number, targetInfo.X, targetInfo.Y, targetInfo.Z)
			if mismatch > config.HitToleranceStuds + slack then
				return reject(session, state, weaponId, "HitMismatch", true, { Offset = round(mismatch) })
			end
			hx, hy, hz = cx :: number, cy :: number, cz :: number
		end

		if targetInfo.Model ~= nil and targetInfo.Model == session.Character then
			return reject(session, state, weaponId, "SelfHit", true)
		end
		if targetInfo.Model ~= nil and not targetInfo.Alive then
			return reject(session, state, weaponId, "TargetDead", true)
		end

		local distance = CombatRules.distance(shooter.ox, shooter.oy, shooter.oz, hx, hy, hz)
		local maxRange = definition.MaxRange * (1 + config.RangeToleranceFraction) + config.RangeToleranceStuds + slack
		if distance > maxRange then
			return reject(session, state, weaponId, "OutOfRange", true, { Distance = round(distance), MaxRange = definition.MaxRange })
		end

		if targetInfo.Player ~= nil then
			local ok, allowed = callProvider("CanDamage", session.Player, targetInfo)
			if not ok or allowed == false then
				return reject(session, state, weaponId, "FriendlyFire", true)
			end
		end

		if checkLineOfSight and definition.RequireLineOfSight and physics and distance > 0 then
			local dx, dy, dz = hx - shooter.ox, hy - shooter.oy, hz - shooter.oz
			local ok, blocked = pcall(physics.Cast, physics, shooter.ox, shooter.oy, shooter.oz, dx, dy, dz, session.Character)
			if ok and blocked ~= nil and blocked < distance - config.LineOfSightEndToleranceStuds then
				return reject(session, state, weaponId, "NoLineOfSight", true, {
					BlockedAt = round(blocked),
					Distance = round(distance),
				})
			end
		end

		local damage = CombatRules.damage(definition, distance, targetInfo.IsHead)
		local calculator = providers.DamageCalculator
		if calculator then
			local ok, custom = pcall(calculator, {
				Attacker = session.Player,
				Weapon = definition,
				Target = targetInfo,
				Distance = distance,
				Headshot = targetInfo.IsHead,
				BaseDamage = damage,
			})
			if ok and type(custom) == "number" and custom == custom and custom >= 0 and custom < math.huge then
				damage = custom
			elseif not ok then
				context.Logger:Error("DamageCalculator errored; using base damage", { Error = tostring(custom) })
			end
		end

		weaponStats(weaponId).Hits += 1
		return {
			Allowed = true,
			ShotAccepted = true,
			Damage = damage,
			Headshot = targetInfo.IsHead,
			Target = targetInfo,
			Distance = distance,
		}
	end

	-- Publishes "Combat.Shot" for behavioural statistics. Event "Shot" is one accepted
	-- shot (Hit says whether it hit a character); "Hit" is a later projectile impact.
	local function publishShot(session: any, definition: Definition, event: string, result: AttackResult?)
		if shotTopic == nil then
			return
		end
		local target = if result then result.Target else nil
		local hit = result ~= nil and result.Allowed and target ~= nil and target.Model ~= nil
		context.Events:Publish(shotTopic :: string, {
			Session = session,
			Weapon = definition.Id,
			WeaponKind = definition.Kind,
			Event = event,
			Hit = hit,
			Headshot = hit and (result :: AttackResult).Headshot,
			Time = context.Clock.Now(),
		})
	end

	local function requireRunning(action: string)
		if context == nil then
			error(`ACF Combat: {action} requires ACF to be started`, 3)
		end
	end

	-- Integration surface -------------------------------------------------------------

	function module:Define(id: string, definition: any)
		if definitions[id] ~= nil then
			error(`ACF Combat: weapon '{tostring(id)}' is already defined`, 2)
		end
		definitions[id] = CombatRules.normalize(id, definition)
	end

	function module:IsDefined(id: string): boolean
		return definitions[id] ~= nil
	end

	function module:GetDefinition(id: string): Definition?
		return definitions[id]
	end

	-- name: "Inventory" (player, weaponId, definition) -> boolean
	--       "CanDamage" (attacker, targetInfo) -> boolean
	--       "DamageCalculator" (info) -> number
	-- Pass nil to restore the default (DamageCalculator default: none).
	function module:SetProvider(name: string, fn: any)
		if not PROVIDERS[name] then
			error(`ACF Combat: unknown provider '{tostring(name)}'`, 2)
		end
		if fn ~= nil and type(fn) ~= "function" then
			error("ACF Combat: provider must be a function or nil", 2)
		end
		if fn == nil then
			providers[name] = if name == "Inventory"
				then defaultInventory
				elseif name == "CanDamage" then defaultCanDamage
				else nil
		else
			providers[name] = fn
		end
	end

	-- Hitscan, Melee and Ability attacks. Claim: { Origin?, Target?, HitPosition? }.
	function module:ValidateAttack(player: any, weaponId: string, claim: Claim): AttackResult
		requireRunning("ValidateAttack")
		local shooter, failure = admitShot(player, weaponId, claim, nil)
		if shooter == nil then
			return failure :: AttackResult
		end
		local result = evaluateHit(shooter, claim, true)
		publishShot(shooter.session, shooter.definition, "Shot", result)
		return result
	end

	-- Registers a projectile at fire time. Claim: { Origin, Direction, ShotId }.
	function module:FireProjectile(player: any, weaponId: string, claim: Claim): AttackResult
		requireRunning("FireProjectile")
		local shooter, failure = admitShot(player, weaponId, claim, "Projectile")
		if shooter == nil then
			return failure :: AttackResult
		end
		local session, state, definition = shooter.session, shooter.state, shooter.definition
		local shotId = claim.ShotId
		if type(shotId) ~= "string" or #shotId == 0 or #shotId > 64 then
			return reject(session, state, weaponId, "InvalidClaim", true, { Problem = "ShotId" })
		end
		local dx, dy, dz = CombatRules.vector(claim.Direction)
		if dx == nil then
			return reject(session, state, weaponId, "InvalidClaim", true, { Problem = "Direction" })
		end
		local length = math.sqrt((dx :: number) ^ 2 + (dy :: number) ^ 2 + (dz :: number) ^ 2)
		if length < 1e-6 then
			return reject(session, state, weaponId, "InvalidClaim", true, { Problem = "Direction" })
		end
		if state.projectiles[shotId] ~= nil then
			return reject(session, state, weaponId, "DuplicateShot", true)
		end

		local now = context.Clock.Now()
		local order = state.projectileOrder
		-- Drop expired and excess projectiles (oldest first).
		while #order > 0 do
			local oldest = state.projectiles[order[1]]
			local expired = oldest == nil
				or now - oldest.t > (definitions[oldest.weapon] :: Definition).ProjectileLifetime + 1
			if expired or #order >= context.Config.MaxPendingProjectiles then
				state.projectiles[order[1]] = nil
				table.remove(order, 1)
			else
				break
			end
		end
		state.projectiles[shotId] = {
			id = shotId,
			weapon = definition.Id,
			t = now,
			ox = shooter.ox,
			oy = shooter.oy,
			oz = shooter.oz,
			dx = (dx :: number) / length,
			dy = (dy :: number) / length,
			dz = (dz :: number) / length,
			pierceLeft = definition.Pierce,
			hitCounted = false,
		}
		table.insert(order, shotId)
		publishShot(session, definition, "Shot", nil)
		return { Allowed = true, ShotAccepted = true, Damage = 0, Headshot = false }
	end

	-- Validates a projectile impact reported after FireProjectile. Claim: { Target?, HitPosition? }.
	function module:ValidateProjectileHit(player: any, shotId: string, claim: Claim): AttackResult
		requireRunning("ValidateProjectileHit")
		if not running then
			return rejected("NotRunning", false)
		end
		local session = context.Players:GetSession(player)
		if session == nil then
			return rejected("NoSession", false)
		end
		local state = combatState(session)
		local projectile = if type(shotId) == "string" then state.projectiles[shotId] else nil
		if projectile == nil then
			return reject(session, state, nil, "UnknownShot", false)
		end
		if type(claim) ~= "table" then
			return reject(session, state, projectile.weapon, "InvalidClaim", true, { Problem = "claim must be a table" })
		end
		local definition = definitions[projectile.weapon] :: Definition
		local config = context.Config
		local now = context.Clock.Now()
		local elapsed = now - projectile.t

		-- Impact point: the claimed hit position, else the target part's position.
		local hx, hy, hz
		if claim.HitPosition ~= nil then
			hx, hy, hz = CombatRules.vector(claim.HitPosition)
		elseif claim.Target ~= nil and context.Platform.Physics and context.Platform.Physics.Describe then
			local ok, info = pcall(context.Platform.Physics.Describe, context.Platform.Physics, claim.Target)
			if ok and info then
				hx, hy, hz = info.X, info.Y, info.Z
			end
		end
		if hx == nil then
			return reject(session, state, projectile.weapon, "InvalidClaim", true, { Problem = "impact position" })
		end
		local ix, iy, iz = hx :: number, hy :: number, hz :: number

		if elapsed > definition.ProjectileLifetime + config.ProjectileTimingToleranceSeconds then
			state.projectiles[shotId] = nil
			return reject(session, state, projectile.weapon, "ProjectileExpired", true, { Elapsed = round(elapsed) })
		end

		local sample = nil
		local physics = context.Platform.Physics
		if session.Character and physics then
			local ok, result = pcall(physics.Sample, physics, session.Character, session.Player)
			sample = if ok then result else nil
		end
		local ping = if sample then pingCompensation(sample) else 0
		local speed = definition.ProjectileSpeed :: number
		local travel = CombatRules.distance(projectile.ox, projectile.oy, projectile.oz, ix, iy, iz)
		local allowedDeviation = config.ProjectileTrajectoryToleranceStuds + travel * config.ProjectileTrajectoryToleranceFraction
		-- Where along the real (possibly arcing) path does it first come within tolerance?
		local arrival, deviation = CombatRules.closestApproach(
			projectile.ox,
			projectile.oy,
			projectile.oz,
			projectile.dx,
			projectile.dy,
			projectile.dz,
			speed,
			definition.ProjectileGravity,
			ix,
			iy,
			iz,
			definition.ProjectileLifetime,
			allowedDeviation
		)
		if arrival == nil then
			return reject(session, state, projectile.weapon, "OffTrajectory", true, {
				Deviation = round(deviation),
				Allowed = round(allowedDeviation),
			})
		end
		if elapsed + ping + config.ProjectileTimingToleranceSeconds < (arrival :: number) then
			return reject(session, state, projectile.weapon, "ProjectileTiming", true, {
				Elapsed = round(elapsed),
				EarliestArrival = round(arrival :: number),
			})
		end

		local shooter: Shooter = {
			session = session,
			state = state,
			definition = definition,
			ws = weaponState(state, definition, now),
			sample = sample or { Ping = 0 },
			ox = projectile.ox,
			oy = projectile.oy,
			oz = projectile.oz,
		}
		local result = evaluateHit(shooter, claim, definition.ProjectileGravity == 0)
		if result.Allowed and result.Target ~= nil and result.Target.Model ~= nil and not projectile.hitCounted then
			projectile.hitCounted = true
			publishShot(session, definition, "Hit", result)
		end
		if result.Allowed and result.Target ~= nil then
			if projectile.pierceLeft > 0 then
				projectile.pierceLeft -= 1
			else
				state.projectiles[shotId] = nil
				local index = table.find(state.projectileOrder, shotId)
				if index then
					table.remove(state.projectileOrder, index)
				end
			end
		end
		return result
	end

	-- Starts a server-side reload. Returns (true) or (false, reason).
	function module:Reload(player: any, weaponId: string): (boolean, string?)
		requireRunning("Reload")
		local session = context.Players:GetSession(player)
		local definition = definitions[weaponId]
		if session == nil or definition == nil or definition.Ammo == nil then
			return false, "not reloadable"
		end
		local ammo = definition.Ammo :: CombatRules.Ammo
		local now = context.Clock.Now()
		local ws = weaponState(combatState(session), definition, now)
		if ws.reloadUntil ~= nil then
			return false, "already reloading"
		end
		if ws.magazine >= ammo.Magazine then
			return false, "magazine full"
		end
		if ws.reserve <= 0 then
			return false, "no reserve ammo"
		end
		if ammo.ReloadSeconds <= 0 then
			finishReload(ws, definition)
		else
			ws.reloadUntil = now + ammo.ReloadSeconds
		end
		return true
	end

	-- Returns magazine, reserve, reloading (server truth).
	function module:GetAmmo(player: any, weaponId: string): (number?, number?, boolean)
		requireRunning("GetAmmo")
		local session = context.Players:GetSession(player)
		local definition = definitions[weaponId]
		if session == nil or definition == nil then
			return nil, nil, false
		end
		local ws = weaponState(combatState(session), definition, context.Clock.Now())
		return ws.magazine, ws.reserve, ws.reloadUntil ~= nil
	end

	-- Server-side ammo grant / sync (pickups, loadouts).
	function module:SetAmmo(player: any, weaponId: string, magazine: number, reserve: number?)
		requireRunning("SetAmmo")
		local definition = definitions[weaponId]
		if definition == nil or definition.Ammo == nil then
			error(`ACF Combat: weapon '{tostring(weaponId)}' has no Ammo definition`, 2)
		end
		local ammo = definition.Ammo :: CombatRules.Ammo
		if type(magazine) ~= "number" or magazine < 0 or magazine > ammo.Magazine or magazine ~= math.floor(magazine) then
			error(`ACF Combat: magazine must be an integer in [0, {ammo.Magazine}]`, 2)
		end
		if reserve ~= nil and (type(reserve) ~= "number" or reserve ~= reserve or reserve < 0) then
			error("ACF Combat: reserve must be a number >= 0", 2)
		end
		local session = context.Players:GetSession(player)
		if session == nil then
			return false
		end
		local ws = weaponState(combatState(session), definition, context.Clock.Now())
		ws.magazine = magazine
		if reserve ~= nil then
			ws.reserve = reserve
		end
		ws.reloadUntil = nil
		return true
	end

	function module:GetStats(): { [string]: any }
		local weapons = {}
		for id, entry in stats do
			weapons[id] = { Shots = entry.Shots, Hits = entry.Hits, Rejected = table.clone(entry.Rejected) }
		end
		return { Weapons = weapons, Rejected = table.clone(globalRejected) }
	end

	-- Lifecycle -----------------------------------------------------------------------

	function module:Initialize(ctx)
		context = ctx
		shotTopic = ctx.Events:Declare("Shot")
	end

	function module:Start()
		running = true
	end

	function module:Stop()
		running = false
	end

	function module:Destroy()
		running = false
		context = nil
	end

	return module
end

return Combat
