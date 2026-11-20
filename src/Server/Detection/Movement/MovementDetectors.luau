--!strict
--[[
	Pure movement detectors. No Roblox APIs: every input is a plain-number sample, so each
	detector is tested against recorded legitimate and malicious traces.

	evaluate() runs, in order:
	  Teleport      consecutive displacement beyond what the allowed speed covers in the
	                elapsed time (+ ping, + slack), or a rise above jump apex.
	  Speed         horizontal distance over a sliding window [MinWindow, MaxWindow].
	  Flight        airborne past the jump airtime while not falling.
	  InfiniteJump  rising again mid-air (after descending) more than MaxAirJumps times.
	  Acceleration  change in reported horizontal velocity per second.
	  Noclip        the segment between samples passes through solid geometry.

	Lag tolerance ("time credit"): the path only records *distinct* positions, and an
	unchanged position keeps its original timestamp. When a frozen client catches up,
	the displacement is measured against the time since it last moved, not against the
	sample interval, so a catch-up burst is not mistaken for speed or teleporting.
	The credit is capped at MaxTimeCreditSeconds: without the cap, a player who stood
	still for a minute could then move WalkSpeed x 60 studs in one sample unflagged
	(found in the Phase 8 Studio run). Freezes longer than the cap are rare, and a single
	resulting violation never reports on its own.

	Every detector returns violations with weights. None of them reports on its own;
	ViolationTracker decides when evidence is sustained.
]]

local Types = require(script.Parent.Parent.Parent.Types)

type Sample = Types.MovementSample

export type Point = { t: number, x: number, y: number, z: number }

export type AirState = {
	since: number,
	peak: number,
	trough: number,
	falling: boolean,
	airJumps: number,
	history: { Point },
	-- Replication-stall credit (see air()): the previous airborne sample and the credit
	-- already granted in this airborne period.
	previous: { t: number, x: number, y: number, z: number }?,
	stallCredit: number,
}

export type State = {
	generation: number,
	path: { Point },
	last: { t: number, x: number, y: number, z: number, vx: number, vz: number }?,
	air: AirState?,
}

export type Violation = {
	Detector: string,
	Kind: string,
	Weight: number,
	Details: { [string]: any },
}

export type Allowances = {
	Teleport: boolean,
	Flight: boolean,
	Noclip: boolean,
	Impulse: boolean,
	SpeedMultiplier: number,
}

export type Settings = {
	MinAllowedSpeed: number,
	SpeedTolerance: number,
	SpeedSlackStuds: number,
	MinWindowSeconds: number,
	MaxWindowSeconds: number,
	MaxPingCompensationSeconds: number,
	TeleportSlackStuds: number,
	TeleportMinDistance: number,
	VerticalSlackStuds: number,
	MaxVerticalPlatformSpeed: number,
	AirborneClearance: number,
	MaxAirtimeExtraSeconds: number,
	MinFallStudsPerSecond: number,
	MaxStallCreditSeconds: number,
	MaxTimeCreditSeconds: number,
	StallMinVelocity: number,
	MaxAirJumps: number,
	AirJumpRiseStuds: number,
	MaxHorizontalAcceleration: number,
	NoclipMinDistance: number,
	NoclipMinThickness: number,
	Detectors: { [string]: boolean },
}

export type CastFn = (ox: number, oy: number, oz: number, dx: number, dy: number, dz: number) -> number?

export type Result = {
	Violations: { Violation },
	ObservedSpeed: number,
	AllowedSpeed: number,
	Airborne: boolean,
}

local MAX_PATH = 48
local MAX_AIR_HISTORY = 24
local SAME_POSITION = 0.05

local AIR_EXEMPT_STATES = { Climbing = true, Swimming = true, Seated = true }

local MovementDetectors = {}

function MovementDetectors.newState(generation: number): State
	return { generation = generation, path = {}, last = nil, air = nil }
end

local function horizontal(ax: number, az: number, bx: number, bz: number): number
	local dx, dz = bx - ax, bz - az
	return math.sqrt(dx * dx + dz * dz)
end

local function round(value: number, places: number?): number
	local scale = 10 ^ (places or 2)
	return math.floor(value * scale + 0.5) / scale
end

function MovementDetectors.allowedSpeed(sample: Sample, settings: Settings, allowances: Allowances): number
	local ground = sample.GroundSpeed
	local platform = if type(ground) == "number" and ground == ground and ground > 0 then ground else 0
	return math.max(sample.WalkSpeed, settings.MinAllowedSpeed) * settings.SpeedTolerance * allowances.SpeedMultiplier
		+ platform * settings.SpeedTolerance
end

local function pingSeconds(sample: Sample, settings: Settings): number
	local ping = sample.Ping
	if ping ~= ping or ping < 0 then
		return 0
	end
	return math.min(ping, settings.MaxPingCompensationSeconds)
end

-- Appends a distinct position; an unchanged position keeps its old timestamp.
local function recordPoint(state: State, point: Point, settings: Settings)
	local path = state.path
	local previous = path[#path]
	if previous then
		local moved = math.abs(point.x - previous.x) + math.abs(point.y - previous.y) + math.abs(point.z - previous.z)
		if moved < SAME_POSITION then
			return
		end
	end
	table.insert(path, point)
	local cutoff = point.t - settings.MaxWindowSeconds
	-- Keep the newest point older than the window: it is the reference across a gap.
	while #path > 2 and path[2].t < cutoff do
		table.remove(path, 1)
	end
	while #path > MAX_PATH do
		table.remove(path, 1)
	end
end

function MovementDetectors.resetPath(state: State, point: Point)
	table.clear(state.path)
	table.insert(state.path, point)
end

-- Oldest recorded point aged within [MinWindow, MaxWindow]; if none, the youngest point
-- older than MaxWindow (the position before a gap).
local function speedReference(state: State, now: number, settings: Settings): Point?
	local reference: Point? = nil
	local path = state.path
	for i = #path, 1, -1 do
		local point = path[i]
		local age = now - point.t
		if age >= settings.MinWindowSeconds then
			if age <= settings.MaxWindowSeconds or reference == nil then
				reference = point
			end
			if age > settings.MaxWindowSeconds then
				break
			end
		end
	end
	return reference
end

local function teleport(state: State, sample: Sample, now: number, settings: Settings, allowedSpeed: number): Violation?
	local previous = state.path[#state.path]
	if previous == nil then
		return nil
	end
	local elapsed = math.clamp(now - previous.t, 0, settings.MaxTimeCreditSeconds)
	local ping = pingSeconds(sample, settings)
	local h = horizontal(previous.x, previous.z, sample.X, sample.Z)
	local allowedH = allowedSpeed * (elapsed + ping) + settings.TeleportSlackStuds
	if h > allowedH and h >= settings.TeleportMinDistance then
		return {
			Detector = "Teleport",
			Kind = "TeleportDetected",
			Weight = 4,
			Details = {
				Distance = round(h),
				AllowedDistance = round(allowedH),
				ElapsedSeconds = round(elapsed),
				Axis = "Horizontal",
			},
		}
	end
	local rise = sample.Y - previous.y
	local apex = if sample.Gravity > 0 then (sample.JumpVelocity * sample.JumpVelocity) / (2 * sample.Gravity) else 0
	local allowedRise = apex + settings.VerticalSlackStuds + settings.MaxVerticalPlatformSpeed * (elapsed + ping)
	if rise > allowedRise then
		return {
			Detector = "Teleport",
			Kind = "TeleportDetected",
			Weight = 4,
			Details = {
				Distance = round(rise),
				AllowedDistance = round(allowedRise),
				ElapsedSeconds = round(elapsed),
				Axis = "Vertical",
			},
		}
	end
	return nil
end

local function speed(state: State, sample: Sample, now: number, settings: Settings, allowedSpeed: number): (Violation?, number)
	local reference = speedReference(state, now, settings)
	if reference == nil then
		return nil, 0
	end
	local elapsed = math.min(now - reference.t, math.max(settings.MaxTimeCreditSeconds, settings.MaxWindowSeconds))
	local distance = horizontal(reference.x, reference.z, sample.X, sample.Z)
	local observed = distance / elapsed
	local allowedDistance = allowedSpeed * (elapsed + pingSeconds(sample, settings)) + settings.SpeedSlackStuds
	if distance <= allowedDistance then
		return nil, observed
	end
	local ratio = distance / allowedDistance
	return {
		Detector = "Speed",
		Kind = "SpeedExceeded",
		Weight = math.min(4, 1 + (ratio - 1) * 2),
		Details = {
			ObservedSpeed = round(observed),
			AllowedSpeed = round(allowedSpeed),
			WindowSeconds = round(elapsed),
			Ratio = round(ratio),
		},
	},
		observed
end

-- Updates airborne tracking; returns (flightViolation?, infiniteJumpViolation?, airborne).
local function air(state: State, sample: Sample, now: number, settings: Settings, allowances: Allowances): (Violation?, Violation?, boolean)
	local grounded = sample.GroundClearance <= settings.AirborneClearance
		or AIR_EXEMPT_STATES[sample.State] == true
		or allowances.Flight
	if grounded then
		state.air = nil
		return nil, nil, false
	end

	local y = sample.Y
	local airState: AirState = state.air
		or { since = now, peak = y, trough = y, falling = false, airJumps = 0, history = {}, previous = nil, stallCredit = 0 }
	state.air = airState

	-- Replication stall: a client that stops sending updates mid-jump (a lag spike)
	-- leaves the server holding its last position AND its last, non-zero velocity. A
	-- position that does not change while the reported velocity says it is moving is a
	-- stall, not a hover (a hovering character reports ~zero velocity). Stalled time is
	-- not counted as airtime, up to MaxStallCreditSeconds per airborne period, so a
	-- cheater cannot hover indefinitely by spoofing velocity while frozen.
	local previous = airState.previous
	if previous then
		local still = math.abs(sample.X - previous.x) < 1e-3 and math.abs(y - previous.y) < 1e-3 and math.abs(sample.Z - previous.z) < 1e-3
		local reportedSpeed = math.sqrt(sample.VX * sample.VX + sample.VY * sample.VY + sample.VZ * sample.VZ)
		if still and reportedSpeed >= settings.StallMinVelocity then
			local credit = math.min(now - previous.t, settings.MaxStallCreditSeconds - airState.stallCredit)
			if credit > 0 then
				airState.since += credit
				airState.stallCredit += credit
				for _, point in airState.history do
					point.t += credit
				end
			end
		end
	end
	airState.previous = { t = now, x = sample.X, y = y, z = sample.Z }
	local history = airState.history
	table.insert(history, { t = now, x = sample.X, y = y, z = sample.Z })
	while #history > MAX_AIR_HISTORY or (#history > 2 and now - history[2].t >= 1.5) do
		table.remove(history, 1)
	end

	-- Infinite jump: a rise of AirJumpRiseStuds after descending, while still airborne.
	local jumpViolation: Violation? = nil
	if not airState.falling then
		airState.peak = math.max(airState.peak, y)
		if airState.peak - y >= 1 then
			airState.falling = true
			airState.trough = y
		end
	else
		airState.trough = math.min(airState.trough, y)
		if y - airState.trough >= settings.AirJumpRiseStuds then
			airState.airJumps += 1
			airState.falling = false
			airState.peak = y
			airState.trough = y
			if airState.airJumps > settings.MaxAirJumps then
				jumpViolation = {
					Detector = "InfiniteJump",
					Kind = "AirJump",
					Weight = 2.5,
					Details = { AirJumps = airState.airJumps, Allowed = settings.MaxAirJumps },
				}
			end
		end
	end

	-- Flight: still airborne after a full jump arc and not falling.
	local flightViolation: Violation? = nil
	if sample.Gravity > 0 then
		local airtime = now - airState.since
		local allowedAirtime = 2 * sample.JumpVelocity / sample.Gravity + settings.MaxAirtimeExtraSeconds
		if airtime > allowedAirtime then
			local reference: Point? = nil
			for i = #history, 1, -1 do
				if now - history[i].t >= 1 then
					reference = history[i]
					break
				end
			end
			if reference then
				local fallRate = (reference.y - y) / (now - reference.t)
				if fallRate < settings.MinFallStudsPerSecond then
					flightViolation = {
						Detector = "Flight",
						Kind = "Flight",
						Weight = 1,
						Details = {
							AirtimeSeconds = round(airtime),
							AllowedAirtimeSeconds = round(allowedAirtime),
							FallRate = round(fallRate),
							GroundClearance = if sample.GroundClearance == math.huge then "none" else round(sample.GroundClearance),
						},
					}
				end
			end
		end
	end
	return flightViolation, jumpViolation, true
end

local function acceleration(state: State, sample: Sample, now: number, settings: Settings): Violation?
	local last = state.last
	if last == nil then
		return nil
	end
	local dt = now - last.t
	if dt <= 0 or dt > 1 then
		return nil
	end
	local accel = horizontal(last.vx, last.vz, sample.VX, sample.VZ) / dt
	if accel > settings.MaxHorizontalAcceleration then
		return {
			Detector = "Acceleration",
			Kind = "AbnormalAcceleration",
			Weight = 1,
			Details = { Acceleration = round(accel), Allowed = settings.MaxHorizontalAcceleration },
		}
	end
	return nil
end

local function noclip(state: State, sample: Sample, settings: Settings, cast: CastFn?): Violation?
	local last = state.last
	if last == nil or cast == nil then
		return nil
	end
	local dx, dy, dz = sample.X - last.x, sample.Y - last.y, sample.Z - last.z
	local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
	if distance < settings.NoclipMinDistance then
		return nil
	end
	local forward = cast(last.x, last.y, last.z, dx, dy, dz)
	if forward == nil or forward >= distance then
		return nil
	end
	-- Rays that start inside a part do not hit it (Roblox semantics). So:
	--   backward hit  -> the segment crossed a solid of thickness distance-forward-backward
	--   backward miss -> the new position is inside the solid the forward ray hit,
	--                    penetrating distance-forward. Collision keeps a legitimate root's
	--                    centre out of walls, so both are evidence of noclip.
	local backward = cast(sample.X, sample.Y, sample.Z, -dx, -dy, -dz)
	local mode, depth
	if backward == nil then
		mode, depth = "Embedded", distance - forward
	else
		mode, depth = "Crossed", distance - forward - backward
	end
	if depth < settings.NoclipMinThickness then
		return nil
	end
	return {
		Detector = "Noclip",
		Kind = "PassedThroughGeometry",
		Weight = 2.5,
		Details = { Mode = mode, Distance = round(distance), Depth = round(depth) },
	}
end

-- Runs all enabled detectors for one sample and advances the state.
function MovementDetectors.evaluate(
	state: State,
	sample: Sample,
	now: number,
	settings: Settings,
	allowances: Allowances,
	cast: CastFn?
): Result
	local enabled = settings.Detectors
	local violations: { Violation } = {}
	local allowedSpeed = MovementDetectors.allowedSpeed(sample, settings, allowances)
	local point: Point = { t = now, x = sample.X, y = sample.Y, z = sample.Z }
	local observed = 0
	local airborne = false

	if allowances.Teleport or allowances.Impulse then
		-- Authorized teleport / physics impulse (knockback, launch pad): displacement is
		-- server-sanctioned, so re-anchor the path at the current position.
		MovementDetectors.resetPath(state, point)
		if allowances.Teleport then
			state.air = nil
		else
			local _, _, isAirborne = air(state, sample, now, settings, allowances)
			airborne = isAirborne
		end
	else
		local teleported: Violation? = if enabled.Teleport then teleport(state, sample, now, settings, allowedSpeed) else nil
		if teleported then
			table.insert(violations, teleported)
			-- Count the jump once, not again in every speed window that spans it.
			MovementDetectors.resetPath(state, point)
			state.air = nil
		elseif enabled.Speed then
			local violation
			violation, observed = speed(state, sample, now, settings, allowedSpeed)
			if violation then
				table.insert(violations, violation)
			end
		end

		local flightViolation, jumpViolation
		flightViolation, jumpViolation, airborne = air(state, sample, now, settings, allowances)
		if flightViolation and enabled.Flight then
			table.insert(violations, flightViolation)
		end
		if jumpViolation and enabled.InfiniteJump then
			table.insert(violations, jumpViolation)
		end

		if enabled.Acceleration and not allowances.Impulse then
			local violation = acceleration(state, sample, now, settings)
			if violation then
				table.insert(violations, violation)
			end
		end

		if enabled.Noclip and not allowances.Noclip and not teleported then
			local violation = noclip(state, sample, settings, cast)
			if violation then
				table.insert(violations, violation)
			end
		end

		recordPoint(state, point, settings)
	end

	state.last = { t = now, x = sample.X, y = sample.Y, z = sample.Z, vx = sample.VX, vz = sample.VZ }
	return {
		Violations = violations,
		ObservedSpeed = observed,
		AllowedSpeed = allowedSpeed,
		Airborne = airborne,
	}
end

return MovementDetectors
