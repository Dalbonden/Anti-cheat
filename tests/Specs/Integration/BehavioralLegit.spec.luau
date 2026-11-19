--[[
	Legitimate behaviour: every scenario must produce NO behavioural evidence. This is the
	false-positive guard for Phase 5; a failure here is a detector bug, not a test bug.

	Scenarios cover varied earning patterns (steady, lumpy, bursty, 2x gamepass, AFK, late
	joiners), server-wide income events, small servers, strong shooters, human clicking
	(including deliberately rhythmic play) and occasional invalid actions.
]]

local Harness = require(script.Parent.BehavioralHarness)

return function(t)
	local expect = t.expect

	local function expectClean(world)
		local flagged = world.flagged()
		if #flagged > 0 then
			local parts = {}
			for _, i in flagged do
				local kinds = {}
				for kind in world.kinds(i) do
					table.insert(kinds, kind)
				end
				table.insert(parts, `P{i}: {table.concat(kinds, ",")}`)
			end
			error({ __testFailure = true, message = "unexpected behavioural evidence: " .. table.concat(parts, "; ") }, 0)
		end
	end

	-- Quantises a time to the next 60 Hz frame, as a Roblox server receives events.
	local function frame(time: number): number
		return math.ceil(time * 60 - 1e-9) / 60
	end

	t.describe("Legitimate behaviour", function()
		t.it("an honest economy with steady, lumpy, bursty, gamepass, AFK and late players", function()
			local w = Harness.world({ Players = 8, Signals = { Coins = {} } })
			local rng = Harness.rng(11)
			for second = 1, 900 do
				for i = 1, 3 do -- steady earners
					w.behavioral:RecordSignal(w.players[i], "Coins", math.max(0, rng.normal(5, 1.5)))
				end
				if second % 20 == 0 then -- quest rewards in lumps
					w.behavioral:RecordSignal(w.players[4], "Coins", 100)
				end
				if rng.chance(0.3) then -- bursty
					w.behavioral:RecordSignal(w.players[5], "Coins", math.max(0, rng.normal(16, 5)))
				end
				w.behavioral:RecordSignal(w.players[6], "Coins", math.max(0, rng.normal(10, 2))) -- 2x gamepass
				if second == 5 then -- earns once, then AFK
					w.behavioral:RecordSignal(w.players[7], "Coins", 40)
				end
				if second > 450 then -- starts playing late
					w.behavioral:RecordSignal(w.players[8], "Coins", math.max(0, rng.normal(5, 1.5)))
				end
				w.advance(1)
			end
			local baseline = w.behavioral:GetBaseline("Coins")
			expect(baseline ~= nil).toBe(true)
			expect(baseline.Source).toBe("Population")
			expect(math.abs(baseline.Mean - 5) < 1.5).toBe(true)
			expectClean(w)
		end)

		t.it("a server-wide double-coins event does not flag anyone", function()
			local w = Harness.world({ Players = 6, Signals = { Coins = {} } })
			local rng = Harness.rng(23)
			for second = 1, 600 do
				local multiplier = if second > 300 then 2.5 else 1
				for i = 1, 6 do
					w.behavioral:RecordSignal(w.players[i], "Coins", math.max(0, rng.normal(5, 1.5)) * multiplier)
				end
				w.advance(1)
			end
			expectClean(w)
		end)

		t.it("a small server has no population baseline, so no statistical reports", function()
			local w = Harness.world({ Players = 2, Signals = { Coins = {} } })
			for _ = 1, 300 do
				w.behavioral:RecordSignal(w.players[1], "Coins", 5)
				w.behavioral:RecordSignal(w.players[2], "Coins", 60)
				w.advance(1)
			end
			expect(w.behavioral:GetBaseline("Coins")).toBeNil()
			expectClean(w)
		end)

		t.it("an income spike shorter than the CUSUM needs is not reported", function()
			local w = Harness.world({ Players = 6, Signals = { Coins = {} } })
			for second = 1, 400 do
				for i = 1, 6 do
					local amount = 5
					if i == 1 and second > 200 and second <= 215 then
						amount = 500 -- a big legitimate payout spread over 15 s
					end
					w.behavioral:RecordSignal(w.players[i], "Coins", amount + (i % 3))
				end
				w.advance(1)
			end
			expectClean(w)
		end)

		t.it("strong and average shooters are not flagged (5 minutes, 9,000 validated shots)", function()
			local w = Harness.world({ Players = 6, Combat = true })
			local rng = Harness.rng(5)
			local accuracy = { 0.3, 0.35, 0.45, 0.5, 0.6, 0.8 }
			local headshots = { 0.15, 0.2, 0.25, 0.3, 0.35, 0.55 }
			for _ = 1, 1500 do
				for i = 1, 6 do
					local outcome = "miss"
					if rng.chance(accuracy[i]) then
						outcome = if rng.chance(headshots[i]) then "head" else "body"
					end
					expect(w.shoot(i, outcome).Allowed).toBe(true)
				end
				w.advance(0.2)
			end
			local profile = w.behavioral:GetProfile(w.players[6])
			expect(profile.Weapons.Rifle.Accuracy > 0.75).toBe(true)
			expect(w.behavioral:GetStats().CombatConnected).toBe(true)
			-- Fire at an exactly regular rate is also not "automation": Combat does not feed
			-- the timing detector.
			expectClean(w)
		end)

		t.it("a strong player alone on a server is judged only by the absolute floor", function()
			local w = Harness.world({ Players = 1, Combat = true })
			local rng = Harness.rng(9)
			for _ = 1, 1500 do
				local outcome = "miss"
				if rng.chance(0.85) then
					outcome = if rng.chance(0.5) then "head" else "body"
				end
				w.shoot(1, outcome)
				w.advance(0.2)
			end
			expectClean(w)
		end)

		t.it("human clicking, including deliberately rhythmic play", function()
			local w = Harness.world({ Players = 3 })
			local rng = Harness.rng(77)
			local times = { 0, 0, 0 }
			local now = 0
			-- P1 casual (CV ~15%), P2 rhythmic (CV ~4%), P3 slow and careful (CV ~8%).
			local means = { 0.3, 0.5, 1.5 }
			local cvs = { 0.15, 0.04, 0.08 }
			local nextAt = { 0.3, 0.5, 1.5 }
			for _ = 1, 4000 do
				local who, soonest = 1, math.huge
				for i = 1, 3 do
					if nextAt[i] < soonest then
						who, soonest = i, nextAt[i]
					end
				end
				local at = frame(soonest)
				if at > now then
					w.advance(at - now)
					now = at
				end
				w.behavioral:RecordAction(w.players[who], "Click")
				times[who] += 1
				nextAt[who] = soonest + math.max(0.05, rng.normal(means[who], means[who] * cvs[who]))
			end
			expect(times[1] > 1000).toBe(true)
			expectClean(w)
		end)

		t.it("occasional invalid actions (clicking Buy while broke) are not reported", function()
			local w = Harness.world({ Players = 1 })
			local rng = Harness.rng(31)
			for minute = 1, 10 do
				for second = 1, 60 do
					local valid = second > 10 or minute % 3 ~= 0
					w.behavioral:RecordAction(w.players[1], "Buy", valid)
					w.advance(frame(math.max(0.1, rng.normal(1, 0.25))))
				end
			end
			-- A frustrated burst: 15 invalid clicks in 5 s, then they stop.
			for _ = 1, 15 do
				w.behavioral:RecordAction(w.players[1], "Buy", false)
				w.advance(frame(math.max(0.1, rng.normal(1 / 3, 0.08))))
			end
			for _ = 1, 120 do
				w.advance(1)
			end
			expectClean(w)
		end)

		t.it("works without Combat and reports it is not connected", function()
			local w = Harness.world({ Players = 4, Signals = { Coins = {} }, Config = { Modules = { Combat = false } } })
			for _ = 1, 60 do
				for i = 1, 4 do
					w.behavioral:RecordSignal(w.players[i], "Coins", 5)
				end
				w.advance(1)
			end
			expect(w.behavioral:GetStats().CombatConnected).toBe(false)
			expect(w.behavioral:GetProfile(w.players[1]).Signals.Coins.MeanRate > 4).toBe(true)
			expectClean(w)
		end)

		t.it("statistics reset when a player leaves and rejoins", function()
			local w = Harness.world({ Players = 1, Signals = { Coins = {} } })
			for _ = 1, 30 do
				w.behavioral:RecordSignal(w.players[1], "Coins", 5)
				w.behavioral:RecordAction(w.players[1], "Click")
				w.advance(1)
			end
			w.fake.Players:Leave(w.players[1])
			w.fake.Players:Join(w.players[1])
			local profile = w.behavioral:GetProfile(w.players[1])
			expect(next(profile.Signals)).toBeNil()
			expect(next(profile.Actions)).toBeNil()
		end)
	end)
end
