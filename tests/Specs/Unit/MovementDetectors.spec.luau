local ACF = game:GetService("ServerScriptService").ACF
local MovementDetectors = require(ACF.Detection.Movement.MovementDetectors)
local ViolationTracker = require(ACF.Intelligence.ViolationTracker)

local SETTINGS = {
	MinAllowedSpeed = 8,
	SpeedTolerance = 1.25,
	SpeedSlackStuds = 4,
	MinWindowSeconds = 0.5,
	MaxWindowSeconds = 2,
	MaxPingCompensationSeconds = 0.5,
	TeleportSlackStuds = 10,
	TeleportMinDistance = 20,
	VerticalSlackStuds = 8,
	MaxVerticalPlatformSpeed = 25,
	AirborneClearance = 1.5,
	MaxAirtimeExtraSeconds = 1,
	MinFallStudsPerSecond = 4,
	MaxStallCreditSeconds = 3,
	MaxTimeCreditSeconds = 3,
	StallMinVelocity = 1,
	MaxAirJumps = 0,
	AirJumpRiseStuds = 3,
	MaxHorizontalAcceleration = 600,
	NoclipMinDistance = 1,
	NoclipMinThickness = 0.5,
	Detectors = { Speed = true, Teleport = true, Flight = true, InfiniteJump = true, Acceleration = true, Noclip = true },
}

local NO_ALLOWANCES = { Teleport = false, Flight = false, Noclip = false, Impulse = false, SpeedMultiplier = 1 }

local function sample(fields)
	local s = {
		X = 0, Y = 3, Z = 0, VX = 0, VY = 0, VZ = 0, AngularSpeed = 0, WalkSpeed = 16,
		JumpVelocity = 50, Gravity = 196.2, GroundClearance = 0, State = "Running",
		Seated = false, Health = 100, Ping = 0,
	}
	for k, v in fields do
		s[k] = v
	end
	return s
end

local function kinds(result)
	local list = {}
	for _, v in result.Violations do
		table.insert(list, v.Kind)
	end
	return list
end

return function(t)
	local expect = t.expect

	t.describe("MovementDetectors", function()
		t.it("allowed speed follows server WalkSpeed with a floor", function()
			expect(MovementDetectors.allowedSpeed(sample({ WalkSpeed = 16 }), SETTINGS, NO_ALLOWANCES)).toBe(20)
			expect(MovementDetectors.allowedSpeed(sample({ WalkSpeed = 0 }), SETTINGS, NO_ALLOWANCES)).toBe(10)
			local boosted = table.clone(NO_ALLOWANCES)
			boosted.SpeedMultiplier = 2
			expect(MovementDetectors.allowedSpeed(sample({ WalkSpeed = 16 }), SETTINGS, boosted)).toBe(40)
		end)

		t.it("gives time credit after a freeze (no speed or teleport on catch-up)", function()
			local state = MovementDetectors.newState(1)
			MovementDetectors.evaluate(state, sample({ X = 0 }), 0, SETTINGS, NO_ALLOWANCES)
			-- Unchanged position for 3 s keeps the t = 0 timestamp.
			for i = 1, 15 do
				MovementDetectors.evaluate(state, sample({ X = 0 }), i * 0.2, SETTINGS, NO_ALLOWANCES)
			end
			local result = MovementDetectors.evaluate(state, sample({ X = 50 }), 3.2, SETTINGS, NO_ALLOWANCES)
			expect(#result.Violations).toBe(0)
		end)

		t.it("weights speed violations by how far they exceed the limit", function()
			local state = MovementDetectors.newState(1)
			for i = 0, 10 do
				MovementDetectors.evaluate(state, sample({ X = i * 0.2 * 40 }), i * 0.2, SETTINGS, NO_ALLOWANCES)
			end
			local result = MovementDetectors.evaluate(state, sample({ X = 11 * 0.2 * 40 }), 2.2, SETTINGS, NO_ALLOWANCES)
			expect(kinds(result)).toEqual({ "SpeedExceeded" })
			local v = result.Violations[1]
			expect(v.Weight > 1 and v.Weight <= 4).toBe(true)
			expect(v.Details.ObservedSpeed).toBeCloseTo(40, 0.5)
		end)

		t.it("re-anchors the path after a teleport so it counts once", function()
			local state = MovementDetectors.newState(1)
			MovementDetectors.evaluate(state, sample({ X = 0 }), 0, SETTINGS, NO_ALLOWANCES)
			MovementDetectors.evaluate(state, sample({ X = 1 }), 0.2, SETTINGS, NO_ALLOWANCES)
			local jump = MovementDetectors.evaluate(state, sample({ X = 500 }), 0.4, SETTINGS, NO_ALLOWANCES)
			expect(kinds(jump)).toEqual({ "TeleportDetected" })
			local after = MovementDetectors.evaluate(state, sample({ X = 501 }), 1.0, SETTINGS, NO_ALLOWANCES)
			expect(#after.Violations).toBe(0)
		end)

		t.it("does not flag a normal jump arc", function()
			local state = MovementDetectors.newState(1)
			local any = 0
			for i = 0, 6 do
				local airT = i * 0.1
				local y = math.max(3, 3 + 50 * airT - 98.1 * airT * airT)
				local result = MovementDetectors.evaluate(
					state,
					sample({ Y = y, GroundClearance = y - 3 }),
					airT,
					SETTINGS,
					NO_ALLOWANCES
				)
				any += #result.Violations
			end
			expect(any).toBe(0)
		end)
	end)

	t.describe("ViolationTracker", function()
		local settings = { HalfLifeSeconds = 10, ReportThreshold = 5, ReportIntervalSeconds = 10, ConfidenceScale = 8 }

		t.it("never reports a single sub-threshold violation", function()
			local tracker = ViolationTracker.new(settings)
			local report = tracker:Record("Speed", 4, 0)
			expect(report).toBe(false)
		end)

		t.it("reports sustained violations and throttles repeats", function()
			local tracker = ViolationTracker.new(settings)
			expect((tracker:Record("Speed", 3, 0))).toBe(false)
			expect((tracker:Record("Speed", 3, 0.2))).toBe(true)
			expect((tracker:Record("Speed", 3, 0.4))).toBe(false)
			expect((tracker:Record("Speed", 3, 11))).toBe(true)
		end)

		t.it("decays by half each half-life", function()
			local tracker = ViolationTracker.new(settings)
			tracker:Record("Speed", 4, 0)
			expect(tracker:Score("Speed", 10)).toBeCloseTo(2, 1e-9)
			expect(tracker:Score("Speed", 20)).toBeCloseTo(1, 1e-9)
		end)

		t.it("caps confidence", function()
			local tracker = ViolationTracker.new({
				HalfLifeSeconds = 10,
				ReportThreshold = 1,
				ReportIntervalSeconds = 0,
				ConfidenceScale = 1,
				MaxConfidence = 0.5,
			})
			local _, _, confidence = tracker:Record("X", 100, 0)
			expect(confidence).toBe(0.5)
		end)

		t.it("keeps keys independent", function()
			local tracker = ViolationTracker.new(settings)
			tracker:Record("A", 4, 0)
			expect(tracker:Score("B", 0)).toBe(0)
		end)
	end)
end
