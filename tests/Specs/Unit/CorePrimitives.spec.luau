local ACF = game:GetService("ServerScriptService").ACF
local Cleanup = require(ACF.Core.Cleanup)
local EventBus = require(ACF.Core.EventBus)
local Logger = require(ACF.Core.Logger)
local RateLimiter = require(ACF.Core.RateLimiter)
local Scheduler = require(ACF.Core.Scheduler)
local Fakes = require(script.Parent.Parent.Fakes)

local function quietLogger(clock)
	local entries = {}
	local logger = Logger.new({
		Level = "Debug",
		Now = clock.Now,
		Wall = clock.Wall,
		Sink = function(entry)
			table.insert(entries, entry)
		end,
	})
	return logger, entries
end

return function(t)
	local expect = t.expect

	t.describe("RateLimiter", function()
		t.it("allows a burst then refills over time", function()
			local clock = Fakes.clock()
			local limiter = RateLimiter.new(3, 1, clock.Now)
			expect(limiter:Allow("a")).toBe(true)
			expect(limiter:Allow("a")).toBe(true)
			expect(limiter:Allow("a")).toBe(true)
			expect(limiter:Allow("a")).toBe(false)
			clock.Advance(1)
			expect(limiter:Allow("a")).toBe(true)
			expect(limiter:Allow("a")).toBe(false)
		end)

		t.it("tracks keys independently", function()
			local clock = Fakes.clock()
			local limiter = RateLimiter.new(1, 1, clock.Now)
			expect(limiter:Allow("a")).toBe(true)
			expect(limiter:Allow("b")).toBe(true)
			expect(limiter:Allow("a")).toBe(false)
		end)

		t.it("keeps key storage bounded", function()
			local clock = Fakes.clock()
			local limiter = RateLimiter.new(2, 1, clock.Now, 8)
			for i = 1, 100 do
				limiter:Allow("k" .. i)
				limiter:Allow("k" .. i)
			end
			expect(limiter:GetStats().Keys <= 8).toBe(true)
			expect(limiter:GetStats().Overflows).toBeGreaterThan(0)
		end)

		t.it("prunes fully refilled buckets before overflowing", function()
			local clock = Fakes.clock()
			local limiter = RateLimiter.new(1, 10, clock.Now, 4)
			for i = 1, 4 do
				limiter:Allow("k" .. i)
			end
			clock.Advance(1)
			limiter:Allow("new")
			expect(limiter:GetStats().Overflows).toBe(0)
			expect(limiter:GetStats().Keys).toBe(1)
		end)
	end)

	t.describe("Cleanup", function()
		t.it("runs tasks in reverse order", function()
			local order = {}
			local bag = Cleanup.new()
			bag:Add(function()
				table.insert(order, 1)
			end)
			bag:Add(function()
				table.insert(order, 2)
			end)
			bag:Clean()
			expect(order).toEqual({ 2, 1 })
			expect(bag:Count()).toBe(0)
		end)

		t.it("disconnects connection-like and destroys destroyable tables", function()
			local signal = Fakes.Signal.new()
			local bag = Cleanup.new()
			bag:Add(signal:Connect(function() end))
			local destroyed = false
			bag:Add({
				Destroy = function()
					destroyed = true
				end,
			})
			bag:Clean()
			expect(signal:ConnectionCount()).toBe(0)
			expect(destroyed).toBe(true)
		end)

		t.it("continues after a failing task and reports it", function()
			local errors = {}
			local ran = false
			local bag = Cleanup.new(function(message)
				table.insert(errors, message)
			end)
			bag:Add(function()
				ran = true
			end)
			bag:Add(function()
				error("boom")
			end)
			expect(bag:Clean()).toBe(1)
			expect(ran).toBe(true)
			expect(#errors).toBe(1)
		end)

		t.it("rejects unsupported values", function()
			expect(function()
				Cleanup.new():Add(42)
			end).toThrow("unsupported")
		end)

		t.it("cancels pending threads", function()
			local bag = Cleanup.new()
			local thread = coroutine.create(function()
				coroutine.yield()
			end)
			coroutine.resume(thread)
			bag:Add(thread)
			expect(bag:Clean()).toBe(0)
			expect(coroutine.status(thread)).toBe("dead")
		end)
	end)

	t.describe("Logger", function()
		t.it("filters by level", function()
			local clock = Fakes.clock()
			local logger, entries = quietLogger(clock)
			logger:SetLevel("Warn")
			logger:Info("hidden")
			logger:Warn("shown")
			expect(#entries).toBe(1)
			expect(entries[1].Message).toBe("shown")
		end)

		t.it("scopes entries and freezes fields", function()
			local clock = Fakes.clock()
			local logger, entries = quietLogger(clock)
			local fields = { A = 1 }
			logger:Scope("Movement"):Info("sample", fields)
			fields.A = 2
			expect(entries[1].Scope).toBe("Movement")
			expect(entries[1].Fields.A).toBe(1)
			expect(table.isfrozen(entries[1].Fields)).toBe(true)
		end)

		t.it("rate limits identical messages and reports the suppressed count", function()
			local clock = Fakes.clock()
			local entries = {}
			local logger = Logger.new({
				Now = clock.Now,
				RateLimitBurst = 2,
				RateLimitWindowSeconds = 10,
				Sink = function(entry)
					table.insert(entries, entry)
				end,
			})
			for _ = 1, 50 do
				logger:Warn("flood")
			end
			expect(#entries).toBe(2)
			expect(logger:GetStats().Suppressed).toBe(48)
			clock.Advance(10)
			logger:Warn("flood")
			expect(entries[3].Suppressed).toBe(48)
		end)

		t.it("keeps a bounded ring buffer readable oldest-first", function()
			local clock = Fakes.clock()
			local logger = Logger.new({ Now = clock.Now, BufferSize = 16, RateLimitBurst = 1000, Sink = function() end })
			for i = 1, 40 do
				logger:Info("entry " .. i)
			end
			local recent = logger:GetRecent()
			expect(#recent).toBe(16)
			expect(recent[1].Message).toBe("entry 25")
			expect(recent[16].Message).toBe("entry 40")
			local lastThree = logger:GetRecent(3)
			expect(lastThree[1].Message).toBe("entry 38")
		end)

		t.it("survives a failing sink", function()
			local clock = Fakes.clock()
			local logger = Logger.new({
				Now = clock.Now,
				Sink = function()
					error("sink down")
				end,
			})
			expect(function()
				logger:Error("still fine")
			end).never.toThrow()
			expect(logger:GetStats().SinkFailures).toBe(1)
		end)

		t.it("formats entries deterministically", function()
			local line = Logger.Format({
				Time = 0,
				WallTime = 0,
				Level = "Warn",
				Scope = "Core",
				Message = "msg",
				Fields = { B = 2, A = "x" },
			})
			expect(line).toBe('[ACF][Warn][Core] msg A="x" B=2')
		end)
	end)

	t.describe("EventBus", function()
		local clock, bus, entries
		t.beforeEach(function()
			clock = Fakes.clock()
			local logger
			logger, entries = quietLogger(clock)
			bus = EventBus.new({ Logger = logger, MaxHandlerFailures = 3, MaxDispatchDepth = 4 })
			bus:RegisterTopic("T")
		end)

		t.it("delivers to subscribers in order", function()
			local seen = {}
			bus:Subscribe("T", function(p)
				table.insert(seen, "a" .. p)
			end)
			bus:Subscribe("T", function(p)
				table.insert(seen, "b" .. p)
			end)
			expect(bus:Publish("T", 1)).toBe(2)
			expect(seen).toEqual({ "a1", "b1" })
		end)

		t.it("rejects unknown topics in strict mode", function()
			expect(function()
				bus:Publish("Nope", nil)
			end).toThrow("unknown topic")
			expect(function()
				bus:Subscribe("Nope", function() end)
			end).toThrow("unknown topic")
		end)

		t.it("isolates handler errors", function()
			local reached = false
			bus:Subscribe("T", function()
				error("bad handler")
			end)
			bus:Subscribe("T", function()
				reached = true
			end)
			expect(bus:Publish("T")).toBe(1)
			expect(reached).toBe(true)
			expect(#Fakes.findLogs(entries, "Event handler failed", "Error")).toBe(1)
		end)

		t.it("disconnects a handler after repeated consecutive failures", function()
			local sub = bus:Subscribe("T", function()
				error("always")
			end, "Broken")
			for _ = 1, 3 do
				bus:Publish("T")
			end
			expect(sub.Connected).toBe(false)
			expect(bus:SubscriberCount("T")).toBe(0)
		end)

		t.it("supports disconnecting during dispatch", function()
			local secondCalls = 0
			local second
			bus:Subscribe("T", function()
				second:Disconnect()
			end)
			second = bus:Subscribe("T", function()
				secondCalls += 1
			end)
			bus:Publish("T")
			bus:Publish("T")
			expect(secondCalls).toBe(0)
			expect(bus:SubscriberCount("T")).toBe(1)
		end)

		t.it("stops runaway recursive publishing at the depth limit", function()
			local calls = 0
			bus:Subscribe("T", function()
				calls += 1
				bus:Publish("T")
			end)
			bus:Publish("T")
			expect(calls).toBe(4)
			expect(#Fakes.findLogs(entries, "Dispatch depth exceeded")).toBe(1)
		end)

		t.it("delivers nothing after Destroy", function()
			local calls = 0
			bus:Subscribe("T", function()
				calls += 1
			end)
			bus:Destroy()
			expect(bus:Publish("T")).toBe(0)
			expect(calls).toBe(0)
		end)
	end)

	t.describe("Scheduler", function()
		local clock, scheduler, entries
		t.beforeEach(function()
			clock = Fakes.clock()
			local logger
			logger, entries = quietLogger(clock)
			scheduler = Scheduler.new({ Now = clock.Now, Logger = logger, MaxConsecutiveFailures = 3 })
		end)

		t.it("runs interval tasks when due and passes dt", function()
			local runs, lastDt = 0, nil
			scheduler:Every("tick", 1, function(_, dt)
				runs += 1
				lastDt = dt
			end)
			scheduler:Step()
			expect(runs).toBe(0)
			clock.Advance(1)
			scheduler:Step()
			expect(runs).toBe(1)
			expect(lastDt).toBe(1)
			clock.Advance(0.5)
			scheduler:Step()
			expect(runs).toBe(1)
		end)

		t.it("skips missed runs after a stall instead of bursting", function()
			local runs = 0
			scheduler:Every("tick", 1, function()
				runs += 1
			end)
			clock.Advance(10)
			scheduler:Step()
			scheduler:Step()
			expect(runs).toBe(1)
		end)

		t.it("runs one-shot tasks once", function()
			local runs = 0
			scheduler:After("once", 2, function()
				runs += 1
			end)
			clock.Advance(2)
			scheduler:Step()
			clock.Advance(2)
			scheduler:Step()
			expect(runs).toBe(1)
			expect(scheduler:ActiveCount()).toBe(0)
		end)

		t.it("cancels tasks via handle", function()
			local runs = 0
			local handle = scheduler:Every("tick", 1, function()
				runs += 1
			end)
			handle:Cancel()
			clock.Advance(5)
			scheduler:Step()
			expect(runs).toBe(0)
			expect(handle:IsActive()).toBe(false)
		end)

		t.it("disables a task after consecutive failures and keeps others running", function()
			local healthy = 0
			scheduler:Every("broken", 1, function()
				error("fail")
			end)
			scheduler:Every("healthy", 1, function()
				healthy += 1
			end)
			for _ = 1, 5 do
				clock.Advance(1)
				scheduler:Step()
			end
			local stats = scheduler:GetStats()
			expect(stats.broken.Failures).toBe(3)
			expect(stats.broken.Disabled).toBe(1)
			expect(healthy).toBe(5)
			expect(#Fakes.findLogs(entries, "disabled after repeated failures")).toBe(1)
		end)

		t.it("validates arguments", function()
			expect(function()
				scheduler:Every("x", 0, function() end)
			end).toThrow("positive")
			expect(function()
				scheduler:Every("x", 0 / 0, function() end)
			end).toThrow("positive")
			expect(function()
				scheduler:After("", 1, function() end)
			end).toThrow("name")
		end)

		t.it("binds to a heartbeat signal", function()
			local heartbeat = Fakes.Signal.new()
			local runs = 0
			scheduler:Every("tick", 1, function()
				runs += 1
			end)
			scheduler:Bind(heartbeat)
			clock.Advance(1)
			heartbeat:Fire()
			expect(runs).toBe(1)
			scheduler:Unbind()
			expect(heartbeat:ConnectionCount()).toBe(0)
		end)
	end)
end
