local ACF = game:GetService("ServerScriptService").ACF
local EvidenceManager = require(ACF.Intelligence.EvidenceManager)
local Logger = require(ACF.Core.Logger)
local Fakes = require(script.Parent.Parent.Fakes)

local function setup(settings)
	local clock = Fakes.clock()
	local counter = 0
	local manager = EvidenceManager.new({
		Clock = { Now = clock.Now, Wall = clock.Wall },
		Logger = Logger.new({ Now = clock.Now, Sink = function() end }),
		GenerateId = function()
			counter += 1
			return "rec-" .. counter
		end,
		Settings = settings or { MaxRecordsPerPlayer = 4, RetentionSeconds = 60, DuplicateWindowSeconds = 5 },
	})
	local eventCount = 0
	local function event(fields)
		eventCount += 1
		local base = {
			Id = "evt-" .. eventCount,
			Detector = "Speed",
			Category = "Movement",
			Kind = "SpeedExceeded",
			UserId = 1,
			SessionId = "s1",
			Severity = 10,
			Confidence = 0.5,
			Time = clock.Now(),
			WallTime = clock.Wall(),
			Details = table.freeze({}),
		}
		for k, v in fields or {} do
			base[k] = v
		end
		return table.freeze(base)
	end
	return manager, clock, event
end

return function(t)
	local expect = t.expect

	t.describe("EvidenceManager", function()
		t.it("creates a record per new detection", function()
			local manager, _, event = setup()
			local record, isNew = manager:Record(event())
			expect(isNew).toBe(true)
			expect(record.Count).toBe(1)
			expect(record.FirstEventId).toBe("evt-1")
			expect(table.isfrozen(record)).toBe(true)
		end)

		t.it("merges duplicates inside the window keeping maxima", function()
			local manager, clock, event = setup()
			manager:Record(event({ Severity = 10, Confidence = 0.9 }))
			clock.Advance(2)
			local record, isNew = manager:Record(event({ Severity = 30, Confidence = 0.4, Details = table.freeze({ N = 2 }) }))
			expect(isNew).toBe(false)
			expect(record.Count).toBe(2)
			expect(record.Severity).toBe(30)
			expect(record.Confidence).toBe(0.9)
			expect(record.Details.N).toBe(2)
			expect(record.LastSeen - record.FirstSeen).toBe(2)
			expect(#manager:Get(1)).toBe(1)
		end)

		t.it("starts a new record once the duplicate window has passed", function()
			local manager, clock, event = setup()
			manager:Record(event())
			clock.Advance(6)
			local _, isNew = manager:Record(event())
			expect(isNew).toBe(true)
			expect(#manager:Get(1)).toBe(2)
		end)

		t.it("keeps different kinds separate", function()
			local manager, _, event = setup()
			manager:Record(event({ Kind = "A" }))
			manager:Record(event({ Kind = "B" }))
			expect(#manager:Get(1)).toBe(2)
		end)

		t.it("evicts the least recently seen record beyond the cap", function()
			local manager, clock, event = setup()
			for i = 1, 5 do
				manager:Record(event({ Kind = "K" .. i }))
				clock.Advance(1)
			end
			local records = manager:Get(1)
			expect(#records).toBe(4)
			expect(records[1].Kind).toBe("K2")
			expect(manager:Summary(1).Evicted).toBe(1)
		end)

		t.it("prunes expired records and empty stores", function()
			local manager, clock, event = setup()
			manager:Record(event())
			clock.Advance(61)
			expect(manager:Prune()).toBe(1)
			expect(manager:GetStats().Users).toBe(0)
		end)

		t.it("filters by detector, category, and time", function()
			local manager, clock, event = setup()
			manager:Record(event({ Detector = "Speed", Kind = "A" }))
			clock.Advance(10)
			manager:Record(event({ Detector = "Fly", Category = "Physics", Kind = "B" }))
			expect(#manager:Get(1, { Detector = "Fly" })).toBe(1)
			expect(#manager:Get(1, { Category = "Movement" })).toBe(1)
			expect(#manager:Get(1, { Since = clock.Now() - 1 })).toBe(1)
		end)

		t.it("summarises counts by category", function()
			local manager, _, event = setup()
			manager:Record(event())
			manager:Record(event())
			manager:Record(event({ Kind = "Other", Category = "Physics" }))
			local summary = manager:Summary(1)
			expect(summary.TotalDetections).toBe(3)
			expect(summary.Merged).toBe(1)
			expect(summary.ByCategory.Movement).toBe(2)
			expect(summary.ByCategory.Physics).toBe(1)
		end)

		t.it("returns snapshots that do not change after later merges", function()
			local manager, _, event = setup()
			local first = manager:Record(event())
			manager:Record(event())
			expect(first.Count).toBe(1)
		end)
	end)
end
