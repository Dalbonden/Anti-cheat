--[[
	Persistent risk: saving at session end (only when justified), seeding the next
	server, batching, retries, DataStore failures, latency races and shutdown flushing.
	A shared fake store stands in for the DataStore across "servers".
]]

local ACF = game:GetService("ServerScriptService").ACF
local Framework = require(ACF.Core.Framework)
local Fakes = require(script.Parent.Parent.Fakes)

local SCOPE = "ACF_Risk_v1"
local ON = { Risk = { Persistence = { Enabled = true } } }

local function server(store, config, clockStart)
	local fake = Fakes.environment({ Store = store, ClockStart = clockStart })
	local framework = Framework.new(fake.Env)
	local probe = Fakes.module("Probe", { Category = "Movement" })
	local probe2 = Fakes.module("Probe2", { Category = "Combat" })
	framework:RegisterModule(probe)
	framework:RegisterModule(probe2)
	framework:Initialize(config or ON)
	framework:Start()
	local s = { framework = framework, fake = fake, store = store }
	function s.join(id)
		return fake.Players:Join(Fakes.player(id or 1))
	end
	function s.report(player, severity, which)
		local module = if which == 2 then probe2 else probe
		module.Context:Report(player, { Kind = "TeleportDetected", Severity = severity, Confidence = 1 })
	end
	function s.advance(seconds)
		local steps = math.max(1, math.ceil(seconds))
		for _ = 1, steps do
			fake.Clock.Advance(seconds / steps)
			framework:Step()
		end
	end
	return s
end

return function(t)
	local expect = t.expect

	t.describe("Risk persistence", function()
		t.it("is off by default: no risk DataStore traffic", function()
			local store = Fakes.store()
			local s = server(store, {})
			local p = s.join()
			s.report(p, 60)
			s.fake.Players:Leave(p)
			s.advance(60)
			s.framework:Stop()
			-- The ban check on join (Enforcement) reads its own store; the risk store is untouched.
			expect(store.ByScope[SCOPE]).toBeNil()
		end)

		t.it("saves only sessions ending at or above MinRiskToSave, in the flush batch", function()
			local store = Fakes.store()
			local s = server(store)
			local high, low = s.join(1), s.join(2)
			s.report(high, 55)
			s.report(low, 30)
			s.fake.Players:Leave(high)
			s.fake.Players:Leave(low)
			local function saves()
				return if store.ByScope[SCOPE] then store.ByScope[SCOPE].Saves else 0
			end
			expect(saves()).toBe(0) -- batched, not written on leave
			s.advance(31)
			expect(saves()).toBe(1)
			local record = store.Data[SCOPE].Risk_1
			expect(record.Version).toBe(1)
			expect(record.Risk >= 40).toBe(true)
			expect(#record.Sessions).toBe(1)
			expect(record.Sessions[1].Top[1].Group).toBe("Movement")
			expect(store.Data[SCOPE].Risk_2).toBeNil()
		end)

		t.it("seeds the next server with weighted, decayed, capped history", function()
			local store = Fakes.store()
			local first = server(store)
			local p = first.join()
			first.report(p, 60)
			first.fake.Players:Leave(p)
			first.framework:Stop() -- flushes the queue
			local saved = store.Data[SCOPE].Risk_1.Risk

			-- Same player, another server, two hours later.
			local second = server(store, nil, 1000 + 7200)
			local again = second.join()
			local r = second.framework:GetRisk(again)
			local expected = math.min(35, saved * 0.5 * 0.5 ^ (2 / 24))
			expect(r.Persistent).toBeCloseTo(expected, 1)
			expect(r.Band).toBe("Increased")
			expect(string.find(r.Explanation, "History", 1, true) ~= nil).toBe(true)
			local history = second.framework:GetRiskHistory(again)
			expect(history[#history].Type).toBe("History")
		end)

		t.it("history alone is capped below the Restrict band", function()
			local store = Fakes.store()
			store.Data[SCOPE] = { Risk_1 = { Version = 1, Risk = 100, WallTime = 1700000000 + 1000, Sessions = {} } }
			local s = server(store, nil, 1000 + 60)
			local p = s.join()
			local r = s.framework:GetRisk(p)
			expect(r.Persistent).toBe(35)
			expect(r.Band).toBe("Increased")
		end)

		t.it("old history fades out (a week later adds nothing)", function()
			local store = Fakes.store()
			store.Data[SCOPE] = { Risk_1 = { Version = 1, Risk = 90, WallTime = 1700000000 + 1000, Sessions = {} } }
			local s = server(store, nil, 1000 + 7 * 86400)
			local p = s.join()
			expect(s.framework:GetRisk(p).Persistent).toBe(0)
		end)

		t.it("a failed load means no history, never an error or added risk", function()
			local store = Fakes.store()
			store.Data[SCOPE] = { Risk_1 = { Version = 1, Risk = 90, WallTime = 1700000000 + 1000, Sessions = {} } }
			store.FailLoads = 1
			local s = server(store, nil, 1060)
			local p = s.join()
			expect(s.framework:GetRisk(p).Risk).toBe(0)
			expect(s.framework:GetStatus().Risk.LoadFailed).toBe(1)
			expect(#Fakes.findLogs(s.fake.Logs, "could not be loaded", "Warn")).toBe(1)
		end)

		t.it("corrupt or foreign records are ignored", function()
			for _, bad in { "text", { Version = 99, Risk = 90, WallTime = 0 }, { Version = 1, Risk = "90", WallTime = 0 } } do
				local store = Fakes.store()
				store.Data[SCOPE] = { Risk_1 = bad }
				local s = server(store)
				local p = s.join()
				expect(s.framework:GetRisk(p).Risk).toBe(0)
			end
		end)

		t.it("a load that completes after the player left is discarded", function()
			local store = Fakes.store()
			store.Data[SCOPE] = { Risk_1 = { Version = 1, Risk = 90, WallTime = 1700000000 + 1000, Sessions = {} } }
			store.Deferred = true
			local s = server(store, nil, 1060)
			local p = s.join()
			s.fake.Players:Leave(p)
			store.Complete()
			expect(s.framework:GetRisk(p).Persistent).toBe(0)
		end)

		t.it("failed saves are retried, then given up after MaxAttempts", function()
			local store = Fakes.store()
			local s = server(store)
			local p1, p2 = s.join(1), s.join(2)
			s.report(p1, 60)
			s.report(p2, 60)
			store.FailSaves = 1 -- first write fails once
			s.fake.Players:Leave(p1)
			s.advance(31)
			s.advance(31)
			expect(store.Data[SCOPE].Risk_1 ~= nil).toBe(true)
			local stats = s.framework:GetStatus().Risk
			expect(stats.SaveRetries).toBe(1)
			expect(stats.Saved).toBe(1)

			store.FailSaves = 10
			s.fake.Players:Leave(p2)
			for _ = 1, 4 do
				s.advance(31)
			end
			stats = s.framework:GetStatus().Risk
			expect(stats.SaveFailed).toBe(1)
			expect(stats.Queued).toBe(0)
			expect(#Fakes.findLogs(s.fake.Logs, "giving up", "Error")).toBe(1)
		end)

		t.it("writes are batched to MaxWritesPerFlush", function()
			local store = Fakes.store()
			local s = server(store, { Risk = { Persistence = { Enabled = true, MaxWritesPerFlush = 3 } } })
			local players = {}
			for id = 1, 7 do
				players[id] = s.join(id)
				s.report(players[id], 60)
			end
			for id = 1, 7 do
				s.fake.Players:Leave(players[id])
			end
			local function saves()
				return if store.ByScope[SCOPE] then store.ByScope[SCOPE].Saves else 0
			end
			s.advance(31)
			expect(saves()).toBe(3)
			s.advance(30)
			expect(saves()).toBe(6)
			s.advance(30)
			expect(saves()).toBe(7)
		end)

		t.it("shutdown flushes everything and reports pending writes until they finish", function()
			local store = Fakes.store()
			local s = server(store)
			local p = s.join()
			s.report(p, 60)
			s.fake.Players:Leave(p)
			store.Deferred = true
			expect(s.fake.Shutdown.Pending()).toBe(1)
			s.fake.Shutdown.Flush()
			expect(s.fake.Shutdown.Pending()).toBe(1) -- in flight
			store.Complete()
			expect(s.fake.Shutdown.Pending()).toBe(0)
			expect(store.Data[SCOPE].Risk_1 ~= nil).toBe(true)
		end)

		t.it("keeps the last MaxSessions session summaries across servers", function()
			local store = Fakes.store()
			for i = 1, 7 do
				local s = server(store, nil, 1000 + i * 3600)
				local p = s.join()
				s.report(p, 60)
				s.report(p, 30, 2)
				s.fake.Players:Leave(p)
				s.framework:Stop()
			end
			local record = store.Data[SCOPE].Risk_1
			expect(#record.Sessions).toBe(5)
			expect(record.Sessions[5].WallTime > record.Sessions[1].WallTime).toBe(true)
		end)

		t.it("ResetRisk with Persistent clears the saved risk but keeps the audit trail", function()
			local store = Fakes.store()
			local s = server(store)
			local p = s.join()
			s.report(p, 60)
			s.fake.Players:Leave(p)
			s.framework:Stop()
			local s2 = server(store, nil, 1000 + 3600)
			local again = s2.join()
			expect(s2.framework:GetRisk(again).Persistent > 0).toBe(true)
			s2.framework:ResetRisk(again, { Persistent = true, Reason = "appeal 7 upheld" })
			s2.advance(31)
			local record = store.Data[SCOPE].Risk_1
			expect(record.Risk).toBe(0)
			expect(record.ResetReason).toBe("appeal 7 upheld")
			expect(#record.Sessions).toBe(1)
			expect(s2.framework:GetRisk(again).Risk).toBe(0)
		end)

		t.it("enabled without a Store warns and runs without persistence", function()
			local fake = Fakes.environment()
			fake.Env.Store = nil
			local framework = Framework.new(fake.Env)
			framework:Initialize(ON)
			framework:Start()
			expect(framework:GetStatus().Risk.Persistence).toBe(false)
			expect(#Fakes.findLogs(fake.Logs, "no Store", "Warn")).toBe(1)
		end)
	end)
end
