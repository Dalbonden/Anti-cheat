--!strict
--[[
	Pure combat rules: weapon/ability definitions, damage, and geometry. No Roblox APIs.

	A definition describes what a weapon or ability is allowed to do. The Combat module
	enforces it; the client never supplies damage, rate, range or ammo.

		Kind = "Hitscan" | "Projectile" | "Melee" | "Ability"
		Damage            number >= 0 (base damage per hit)
		HeadshotMultiplier number >= 1 (default 1)
		Falloff           { Start, End, MinMultiplier } (optional; linear between Start and End)
		FireRate          shots per second (optional for Ability/Melee; required for Hitscan/Projectile)
		Burst             shots allowed back-to-back above FireRate (default 1, i.e. no burst)
		Cooldown          seconds between uses (default 0)
		MaxRange          studs (required)
		Ammo              { Magazine, Reserve (number or math.huge), ReloadSeconds } (optional = infinite)
		ProjectileSpeed   studs/s (required for Projectile)
		ProjectileGravity studs/s^2 downward (default 0)
		ProjectileLifetime seconds (default 5)
		Pierce            extra targets one projectile may hit (default 0)
		RequireLineOfSight boolean (default true)
		RequireTarget     boolean (default false for Ability, true for Melee, false otherwise)
]]

export type Falloff = { Start: number, End: number, MinMultiplier: number }
export type Ammo = { Magazine: number, Reserve: number, ReloadSeconds: number }

export type Definition = {
	Id: string,
	Kind: "Hitscan" | "Projectile" | "Melee" | "Ability",
	Damage: number,
	HeadshotMultiplier: number,
	Falloff: Falloff?,
	FireRate: number?,
	Burst: number,
	Cooldown: number,
	MaxRange: number,
	Ammo: Ammo?,
	ProjectileSpeed: number?,
	ProjectileGravity: number,
	ProjectileLifetime: number,
	Pierce: number,
	RequireLineOfSight: boolean,
	RequireTarget: boolean,
}

local KINDS = { Hitscan = true, Projectile = true, Melee = true, Ability = true }
local FIELDS = {
	Kind = true,
	Damage = true,
	HeadshotMultiplier = true,
	Falloff = true,
	FireRate = true,
	Burst = true,
	Cooldown = true,
	MaxRange = true,
	Ammo = true,
	ProjectileSpeed = true,
	ProjectileGravity = true,
	ProjectileLifetime = true,
	Pierce = true,
	RequireLineOfSight = true,
	RequireTarget = true,
}

local CombatRules = {}

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Validates a definition. Raises at the caller's caller with a precise message.
function CombatRules.normalize(id: any, raw: any): Definition
	local function fail(message: string): never
		error(`ACF Combat: '{tostring(id)}': {message}`, 4)
	end
	if type(id) ~= "string" or #id == 0 or #id > 64 then
		error("ACF Combat: weapon id must be a non-empty string of at most 64 characters", 4)
	end
	if type(raw) ~= "table" then
		fail("definition must be a table")
	end
	for key in raw do
		if not FIELDS[key] then
			fail(`unknown field '{tostring(key)}'`)
		end
	end
	local kind = raw.Kind
	if not KINDS[kind] then
		fail("Kind must be Hitscan, Projectile, Melee or Ability")
	end
	local function number(name: string, default: number?, min: number, allowHuge: boolean?): number
		local value = raw[name]
		if value == nil then
			if default == nil then
				fail(`{name} is required`)
			end
			return default :: number
		end
		local ok = if allowHuge then (type(value) == "number" and value == value) else finite(value)
		if not ok or value < min then
			fail(`{name} must be a number >= {min}`)
		end
		return value
	end

	local damage = number("Damage", 0, 0)
	local maxRange = number("MaxRange", nil, 0.01)
	local fireRate: number? = nil
	if raw.FireRate ~= nil or kind == "Hitscan" or kind == "Projectile" then
		fireRate = number("FireRate", nil, 0.001)
	end
	local burst = number("Burst", 1, 1)
	if burst ~= math.floor(burst) then
		fail("Burst must be an integer")
	end

	local falloff: Falloff? = nil
	if raw.Falloff ~= nil then
		local f = raw.Falloff
		if type(f) ~= "table" or not finite(f.Start) or not finite(f.End) or not finite(f.MinMultiplier) then
			fail("Falloff must be { Start, End, MinMultiplier }")
		end
		if f.Start < 0 or f.End <= f.Start or f.MinMultiplier < 0 or f.MinMultiplier > 1 then
			fail("Falloff needs 0 <= Start < End and 0 <= MinMultiplier <= 1")
		end
		falloff = table.freeze({ Start = f.Start, End = f.End, MinMultiplier = f.MinMultiplier })
	end

	local ammo: Ammo? = nil
	if raw.Ammo ~= nil then
		local a = raw.Ammo
		if type(a) ~= "table" then
			fail("Ammo must be { Magazine, Reserve, ReloadSeconds }")
		end
		local magazine = a.Magazine
		if not finite(magazine) or magazine < 1 or magazine ~= math.floor(magazine) then
			fail("Ammo.Magazine must be an integer >= 1")
		end
		local reserve = if a.Reserve == nil then math.huge else a.Reserve
		if type(reserve) ~= "number" or reserve ~= reserve or reserve < 0 then
			fail("Ammo.Reserve must be a number >= 0 (math.huge for unlimited)")
		end
		local reload = if a.ReloadSeconds == nil then 0 else a.ReloadSeconds
		if not finite(reload) or reload < 0 then
			fail("Ammo.ReloadSeconds must be a number >= 0")
		end
		ammo = table.freeze({ Magazine = magazine, Reserve = reserve, ReloadSeconds = reload })
	end

	local projectileSpeed: number? = nil
	if kind == "Projectile" then
		projectileSpeed = number("ProjectileSpeed", nil, 0.01)
	elseif raw.ProjectileSpeed ~= nil then
		fail("ProjectileSpeed only applies to Kind = Projectile")
	end

	local pierce = number("Pierce", 0, 0)
	if pierce ~= math.floor(pierce) then
		fail("Pierce must be an integer")
	end

	local function boolean(name: string, default: boolean): boolean
		local value = raw[name]
		if value == nil then
			return default
		end
		if type(value) ~= "boolean" then
			fail(`{name} must be a boolean`)
		end
		return value
	end

	return table.freeze({
		Id = id,
		Kind = kind,
		Damage = damage,
		HeadshotMultiplier = number("HeadshotMultiplier", 1, 1),
		Falloff = falloff,
		FireRate = fireRate,
		Burst = burst,
		Cooldown = number("Cooldown", 0, 0),
		MaxRange = maxRange,
		Ammo = ammo,
		ProjectileSpeed = projectileSpeed,
		ProjectileGravity = number("ProjectileGravity", 0, 0),
		ProjectileLifetime = number("ProjectileLifetime", 5, 0.01),
		Pierce = pierce,
		RequireLineOfSight = boolean("RequireLineOfSight", true),
		RequireTarget = boolean("RequireTarget", kind == "Melee"),
	}) :: any
end

-- Server-computed damage for a hit at `distance`.
function CombatRules.damage(definition: Definition, distance: number, headshot: boolean): number
	local multiplier = 1
	local falloff = definition.Falloff
	if falloff then
		if distance >= falloff.End then
			multiplier = falloff.MinMultiplier
		elseif distance > falloff.Start then
			local t = (distance - falloff.Start) / (falloff.End - falloff.Start)
			multiplier = 1 - t * (1 - falloff.MinMultiplier)
		end
	end
	if headshot then
		multiplier *= definition.HeadshotMultiplier
	end
	return definition.Damage * multiplier
end

function CombatRules.distance(ax: number, ay: number, az: number, bx: number, by: number, bz: number): number
	local dx, dy, dz = bx - ax, by - ay, bz - az
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Where a projectile fired from origin along unit direction (dx,dy,dz) at `speed`,
-- with downward `gravity`, is after `t` seconds.
function CombatRules.projectilePosition(
	ox: number,
	oy: number,
	oz: number,
	dx: number,
	dy: number,
	dz: number,
	speed: number,
	gravity: number,
	t: number
): (number, number, number)
	return ox + dx * speed * t, oy + dy * speed * t - 0.5 * gravity * t * t, oz + dz * speed * t
end

-- Earliest flight time at which the projectile passes within `tolerance` of point h,
-- searched over [0, maxTime]. Returns (time, deviation) for that moment, or
-- (nil, minimumDeviation) if the path never comes within tolerance. Handles arcs:
-- a lobbed shot that passes near h on the way up is matched on that first pass.
function CombatRules.closestApproach(
	ox: number,
	oy: number,
	oz: number,
	dx: number,
	dy: number,
	dz: number,
	speed: number,
	gravity: number,
	hx: number,
	hy: number,
	hz: number,
	maxTime: number,
	tolerance: number
): (number?, number)
	local function deviationAt(t: number): number
		local px, py, pz = CombatRules.projectilePosition(ox, oy, oz, dx, dy, dz, speed, gravity, t)
		return CombatRules.distance(px, py, pz, hx, hy, hz)
	end
	local steps = 96
	local step = maxTime / steps
	local minimum = math.huge
	for i = 0, steps do
		local t = i * step
		local deviation = deviationAt(t)
		minimum = math.min(minimum, deviation)
		if deviation <= tolerance then
			-- Refine the first entry into tolerance by bisection on [t - step, t].
			local lo, hi = math.max(0, t - step), t
			for _ = 1, 24 do
				local mid = (lo + hi) / 2
				if deviationAt(mid) <= tolerance then
					hi = mid
				else
					lo = mid
				end
			end
			return hi, deviationAt(hi)
		end
	end
	return nil, minimum
end

-- Reads a Vector3-like claim value as finite numbers, or nil if it is not one.
function CombatRules.vector(value: any): (number?, number?, number?)
	if typeof(value) ~= "Vector3" then
		return nil, nil, nil
	end
	local x, y, z = value.X, value.Y, value.Z
	if not (finite(x) and finite(y) and finite(z)) then
		return nil, nil, nil
	end
	return x, y, z
end

return CombatRules
