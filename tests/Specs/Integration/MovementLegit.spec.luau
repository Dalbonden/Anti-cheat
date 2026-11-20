--[[
	False-positive guard: legitimate play that must NEVER produce movement or physics
	evidence. Every scenario runs through the full framework with a fake world (floor at
	y = 0, standing root height 3) and 0.2 s server samples.
]]

local ACF = game:GetService("ServerScriptService").ACF
local Framework = require(ACF.Core.Framework)
local Fakes = require(script.Parent.Parent.Fakes)

local DT = 0.2

local function setup(config)
	local fake = Fakes.environment()
	fake.Physics:AddFloor()
	local framework = Framework.new(fake.Env)
	framework:Initialize(config or {})
	framework:Start()
	local player = fake.Players:Join(Fakes.player(1))
	local character = player:Spawn()
	fake.Physics:Set(character, {})
	local world = { framework = framework, fake = fake, player = player, character = character, t = 0 }
	-- Advances one sample: applies fields, moves the clock, runs scheduled work.
	function world.step(fields)
		world.t += DT
		if fields then
			fake.Physics:Set(world.character, fields)
		end
		fake.Clock.Advance(DT)
		framework:Step()
	end
	function world.evidence()
		local movementOrPhysics = {}
		for _, record in framework:GetEvidence(player) do
			if record.Category == "Movement" or record.Category == "Physics" then
				table.insert(movementOrPhysics, record)
			end
		end
		return movementOrPhysics
	end
	return world
end

local function describeEvidence(records)
	local kinds = {}
	for _, r in records do
		table.insert(kinds, r.Kind)
	end
	return table.concat(kinds, ", ")
end

return function(t)
	local expect = t.expect

	local function expectClean(world)
		local records = world.evidence()
		if #records > 0 then
			error({ __testFailure = true, message = "unexpected evidence: " .. describeEvidence(records) }, 0)
		end
		expect(world.framework:GetModule("Movement"):GetStats().Samples > 0).toBe(true)
	end

	t.describe("Legitimate movement produces no evidence", function()
		t.it("walking at WalkSpeed for 20 seconds, changing direction", function()
			local w = setup()
			local x, z = 0, 0
			for i = 1, 100 do
				local dirX = if (i // 10) % 2 == 0 then 1 else 0
				local dirZ = 1 - dirX
				x += 16 * DT * dirX
				z += 16 * DT * dirZ
				w.step({ X = x, Z = z, VX = 16 * dirX, VZ = 16 * dirZ })
			end
			expectClean(w)
		end)

		t.it("sprinting after the server raises WalkSpeed", function()
			local w = setup()
			local x = 0
			for _ = 1, 60 do
				x += 32 * DT
				w.step({ X = x, VX = 32, WalkSpeed = 32 })
			end
			expectClean(w)
		end)

		t.it("lag: a 1.5 s freeze followed by a catch-up burst", function()
			local w = setup()
			local x = 0
			for i = 1, 60 do
				x += 16 * DT
				local frozen = i >= 20 and i < 28
				if not frozen then
					w.step({ X = x, VX = 16 })
				else
					w.step(nil)
				end
			end
			expectClean(w)
		end)

		t.it("lag: a 3 s freeze longer than the speed window", function()
			local w = setup()
			local x = 0
			for i = 1, 80 do
				x += 16 * DT
				if i >= 20 and i < 35 then
					w.step(nil)
				else
					w.step({ X = x, VX = 16 })
				end
			end
			expectClean(w)
		end)

		t.it("high ping with jittery delivery", function()
			local w = setup()
			local x = 0
			for i = 1, 80 do
				x += 16 * DT
				-- Alternate stalls and double-steps as packets bunch up.
				if i % 3 == 0 then
					w.step({ Ping = 0.4 })
				else
					w.step({ X = x, VX = 16, Ping = 0.4 })
				end
			end
			expectClean(w)
		end)

		t.it("lag: a 2.8 s freeze in mid-air, then the catch-up landing (found by the Phase 8 simulation)", function()
			local w = setup()
			local x = 0
			for _ = 1, 10 do
				x += 14 * DT
				w.step({ X = x, VX = 14 })
			end
			-- Jump: rising for two samples, then the client stops sending updates. The
			-- server keeps the last position and the last (non-zero) velocity.
			w.step({ X = x + 2.8, Y = 11, VX = 14, VY = 30, State = "Jumping" })
			w.step({ X = x + 5.6, Y = 13.5, VX = 14, VY = 11, State = "Jumping" })
			for _ = 1, 14 do
				w.step()
			end
			-- Updates resume: the character has long since landed further on.
			w.step({ X = x + 40, Y = 3, VX = 14, VY = 0, State = "Running" })
			for i = 1, 10 do
				w.step({ X = x + 40 + i * 2.8, VX = 14 })
			end
			expectClean(w)
		end)

		t.it("repeated normal jumps while walking", function()
			local w = setup()
			local x, airT = 0, nil
			for i = 1, 100 do
				x += 16 * DT
				if i % 6 == 0 then
					airT = 0
				end
				local y = 3
				if airT then
					airT += DT
					y = 3 + 50 * airT - 98.1 * airT * airT
					if y <= 3 then
						y, airT = 3, nil
					end
				end
				w.step({ X = x, Y = y, VX = 16, VY = 0 })
			end
			expectClean(w)
		end)

		t.it("falling off a high ledge", function()
			local w = setup()
			w.fake.Physics:AddBox(-10, -10, -10, 10, 600, 10) -- tower, top at y = 600
			local x, y, vy = 0, 603, 0
			for i = 1, 60 do
				x += 16 * DT
				if x > 10 then
					vy -= 196.2 * DT
					y = math.max(3, y + vy * DT)
				end
				w.step({ X = x, Y = y, VX = 16, VY = vy })
				if y <= 3 then
					vy = 0
				end
				local _ = i
			end
			expectClean(w)
		end)

		t.it("respawning far away", function()
			local w = setup()
			for i = 1, 10 do
				w.step({ X = i })
			end
			w.character = w.player:Spawn()
			w.fake.Physics:Set(w.character, { X = 5000, Z = -3000 })
			for i = 1, 20 do
				w.step({ X = 5000 + i })
			end
			expectClean(w)
		end)

		t.it("server-authorized teleport", function()
			local w = setup()
			for i = 1, 10 do
				w.step({ X = i })
			end
			w.framework:GetModule("Movement"):AuthorizeTeleport(w.player)
			w.step({ X = 9000, Y = 503 })
			w.fake.Physics:AddBox(8000, 490, -1000, 10000, 500, 1000)
			for i = 1, 30 do
				w.step({ X = 9000 + i })
			end
			expectClean(w)
		end)

		t.it("driving a vehicle, then getting out", function()
			local w = setup()
			local x = 0
			for _ = 1, 30 do
				x += 120 * DT
				w.step({ X = x, VX = 120, Seated = true, State = "Seated" })
			end
			for _ = 1, 20 do
				x += 16 * DT
				w.step({ X = x, VX = 16, Seated = false, State = "Running" })
			end
			expectClean(w)
		end)

		t.it("climbing a tall ladder", function()
			local w = setup()
			local y = 3
			for _ = 1, 50 do
				y += 8 * DT
				w.step({ Y = y, VY = 8, State = "Climbing" })
			end
			expectClean(w)
		end)

		t.it("swimming at the surface", function()
			local w = setup()
			local x = 0
			for _ = 1, 50 do
				x += 12 * DT
				w.step({ X = x, VX = 12, Y = 40, GroundClearance = 37, State = "Swimming" })
			end
			expectClean(w)
		end)

		t.it("dying (ragdoll flung away) and respawning", function()
			local w = setup()
			w.step({ X = 1 })
			for i = 1, 10 do
				w.step({ Health = 0, State = "Dead", X = i * 50, AngularSpeed = 400 })
			end
			w.character = w.player:Spawn()
			w.fake.Physics:Set(w.character, {})
			for i = 1, 10 do
				w.step({ X = i })
			end
			expectClean(w)
		end)

		t.it("a game dash granted with AllowMovement Speed", function()
			local w = setup()
			local x = 0
			for _ = 1, 10 do
				x += 16 * DT
				w.step({ X = x, VX = 16 })
			end
			w.framework:GetModule("Movement"):Allow(w.player, "Speed", 1, { Multiplier = 4 })
			for _ = 1, 5 do
				x += 60 * DT
				w.step({ X = x, VX = 60 })
			end
			for _ = 1, 30 do
				x += 16 * DT
				w.step({ X = x, VX = 16 })
			end
			expectClean(w)
		end)

		t.it("knockback granted with AllowMovement Impulse", function()
			local w = setup()
			w.step({ X = 0 })
			w.framework:GetModule("Movement"):Allow(w.player, "Impulse", 1)
			local x = 0
			for _ = 1, 4 do
				x += 250 * DT
				w.step({ X = x, VX = 250, VY = 120, AngularSpeed = 90 })
			end
			for i = 1, 30 do
				w.step({ X = x + i * 0.5, VX = 2, VY = 0, AngularSpeed = 0 })
			end
			expectClean(w)
		end)

		t.it("walking alongside a wall and through an open doorway", function()
			local w = setup()
			-- Wall at x = 20 with a doorway gap between z = -3 and z = 3.
			w.fake.Physics:AddBox(19, 0, -100, 21, 20, -3)
			w.fake.Physics:AddBox(19, 0, 3, 21, 20, 100)
			local x = 0
			for _ = 1, 40 do
				x += 16 * DT
				w.step({ X = x, Z = 0, VX = 16 })
			end
			expectClean(w)
		end)

		t.it("standing still for a long time, then walking", function()
			local w = setup()
			for _ = 1, 100 do
				w.step(nil)
			end
			local x = 0
			for _ = 1, 30 do
				x += 16 * DT
				w.step({ X = x, VX = 16 })
			end
			expectClean(w)
		end)

		t.it("riding a moving train while walking along it", function()
			local w = setup()
			local x = 0
			for _ = 1, 60 do
				x += (60 + 16) * DT
				w.step({ X = x, VX = 76, GroundSpeed = 60 })
			end
			expectClean(w)
		end)

		t.it("double jump allowed by configuration", function()
			local w = setup({ ModuleSettings = { Movement = { MaxAirJumps = 1 } } })
			local samples = { 3, 9, 13, 14, 12, 18, 21, 21, 18, 12, 4, 3, 3 }
			for _ = 1, 3 do
				for _, y in samples do
					w.step({ Y = y })
				end
				for _ = 1, 10 do
					w.step(nil)
				end
			end
			expectClean(w)
		end)
	end)
end
