local ACF = game:GetService("ServerScriptService").ACF
local Configuration = require(ACF.Core.Configuration)
local DefaultConfig = require(ACF.Core.DefaultConfig)
local EnforcementPolicy = require(ACF.Enforcement.EnforcementPolicy)
local BanRecords = require(ACF.Enforcement.BanRecords)

-- The resolved Enforcement configuration, with overrides.
local function settings(overrides)
	local config = Configuration.new(DefaultConfig())
	local ok, errors = config:Load({ Enforcement = overrides or {} })
	assert(ok, errors and table.concat(errors, "\n"))
	return config:Get("Enforcement")
end

local function input(band, groups, confidence, kicks, tempBans)
	local list = {}
	for group, score in groups or {} do
		table.insert(list, { Group = group, Score = score })
	end
	table.sort(list, function(a, b)
		return a.Score > b.Score
	end)
	return {
		Band = band,
		Risk = 0,
		Confidence = confidence or 0.95,
		Groups = list,
		RecentKicks = kicks or 0,
		TemporaryBans = tempBans or 0,
	}
end

return function(t)
	local expect = t.expect

	t.describe("EnforcementPolicy", function()
		t.it("maps bands to levels 0-4", function()
			local cfg = settings()
			expect(EnforcementPolicy.decide(input("Normal"), cfg).Level).toBe(0)
			expect(EnforcementPolicy.decide(input("Increased"), cfg).Level).toBe(1)
			expect(EnforcementPolicy.decide(input("Restrict"), cfg).Level).toBe(2)
			expect(EnforcementPolicy.decide(input("Investigation"), cfg).Level).toBe(3)
			local review = EnforcementPolicy.decide(input("EnforcementReview", { Combat = 10 }, 0.5), cfg)
			expect(review.Level).toBe(4)
			expect(review.Proposed).toBe(5)
		end)

		t.it("tags are groups at or above TagMinScore", function()
			local d = EnforcementPolicy.decide(input("Restrict", { Economy = 30, Movement = 14.9, Aim = 15 }), settings())
			table.sort(d.Tags)
			expect(d.Tags).toEqual({ "Aim", "Economy" })
		end)

		t.it("Mode Off logs only", function()
			local d = EnforcementPolicy.decide(input("EnforcementReview", { Movement = 90 }), settings({ Mode = "Off" }))
			expect(d.Level).toBe(0)
			expect(d.Proposed).toBeNil()
		end)

		t.it("kicks automatically on strong non-statistical evidence (Hybrid, AutoKick)", function()
			local d = EnforcementPolicy.decide(input("EnforcementReview", { Movement = 45, Combat = 40 }), settings())
			expect(d.Level).toBe(5)
			expect(d.Corroborated).toBe(true)
			expect(d.Proposed).toBeNil()
		end)

		t.it("two independent groups corroborate when at least one is non-statistical", function()
			local ok = EnforcementPolicy.corroborated(input("EnforcementReview", { Movement = 20, Aim = 30 }), settings())
			expect(ok).toBe(true)
		end)

		t.it("statistical evidence alone never corroborates", function()
			local d = EnforcementPolicy.decide(input("EnforcementReview", { Aim = 50, Economy = 40, Automation = 30 }, 0.99), settings())
			expect(d.Corroborated).toBe(false)
			expect(d.Level).toBe(4)
			expect(d.Proposed).toBe(5)
			expect(string.find(d.Reason, "only statistical", 1, true) ~= nil).toBe(true)
		end)

		t.it("low confidence, AutoKick = false and Manual mode all become proposals", function()
			local strong = { Movement = 60, Combat = 30 }
			expect(EnforcementPolicy.decide(input("EnforcementReview", strong, 0.8), settings()).Proposed).toBe(5)
			expect(EnforcementPolicy.decide(input("EnforcementReview", strong), settings({ AutoKick = false })).Proposed).toBe(5)
			local manual = EnforcementPolicy.decide(input("EnforcementReview", strong), settings({ Mode = "Manual" }))
			expect(manual.Level).toBe(4)
			expect(manual.Proposed).toBe(5)
		end)

		t.it("escalates: repeated kicks -> temporary ban; temporary bans -> permanent proposal", function()
			local strong = { Movement = 60, Combat = 30 }
			local d = EnforcementPolicy.decide(input("EnforcementReview", strong, 0.95, 2, 0), settings())
			expect(d.Proposed).toBe(6) -- AutoBan is off by default
			local auto = EnforcementPolicy.decide(input("EnforcementReview", strong, 0.95, 2, 0), settings({ AutoBan = true }))
			expect(auto.Level).toBe(6)
			local perm = EnforcementPolicy.decide(input("EnforcementReview", strong, 0.95, 0, 2), settings({ AutoBan = true }))
			expect(perm.Level).toBe(4)
			expect(perm.Proposed).toBe(7) -- permanent bans need approval by default
			local unattended = EnforcementPolicy.decide(
				input("EnforcementReview", strong, 0.95, 0, 2),
				settings({ AutoBan = true, Bans = { RequireApprovalForPermanentBan = false } })
			)
			expect(unattended.Level).toBe(7)
		end)
	end)

	t.describe("BanRecords", function()
		t.it("accepts valid stored records and rejects foreign ones", function()
			expect(BanRecords.fromStored(1, "x")).toBeNil()
			expect(BanRecords.fromStored(1, { Version = 2 })).toBeNil()
			local record = BanRecords.fromStored(1, {
				Version = 1,
				Active = { Level = 6, IssuedAt = 100, ExpiresAt = 200, AppealRef = "ACF-1", Reason = string.rep("x", 1000) },
				History = { { Type = "Kick", At = 50 }, { Type = 5, At = 1 }, "junk" },
			})
			expect(record.Active.Level).toBe(6)
			expect(#record.Active.Reason).toBe(400)
			expect(#record.History).toBe(1)
			local badLevel = BanRecords.fromStored(1, { Version = 1, Active = { Level = 9, IssuedAt = 1 }, History = {} })
			expect(badLevel.Active).toBeNil()
		end)

		t.it("temporary bans expire into history; permanent bans do not", function()
			local record = BanRecords.new(1)
			record.Active = { Level = 6, AppealRef = "ACF-A", Reason = "", By = "x", IssuedAt = 0, ExpiresAt = 100 }
			expect(BanRecords.activeBan(record, 99) ~= nil).toBe(true)
			expect(BanRecords.activeBan(record, 100)).toBeNil()
			expect(BanRecords.expire(record, 150, 20)).toBe(true)
			expect(record.Active).toBeNil()
			expect(record.History[1].Type).toBe("Expired")
			record.Active = { Level = 7, AppealRef = "ACF-B", Reason = "", By = "x", IssuedAt = 0, ExpiresAt = nil }
			expect(BanRecords.expire(record, 1e12, 20)).toBe(false)
			expect(BanRecords.activeBan(record, 1e12) ~= nil).toBe(true)
		end)

		t.it("temporary ban length escalates and is capped", function()
			local record = BanRecords.new(1)
			expect(BanRecords.tempBanHours(record, 24, 2, 720)).toBe(24)
			BanRecords.addHistory(record, { Type = "TemporaryBan", At = 1 }, 20)
			BanRecords.addHistory(record, { Type = "TemporaryBan", At = 2 }, 20)
			expect(BanRecords.tempBanHours(record, 24, 2, 720)).toBe(96)
			for i = 1, 10 do
				BanRecords.addHistory(record, { Type = "TemporaryBan", At = 2 + i }, 20)
			end
			expect(BanRecords.tempBanHours(record, 24, 2, 720)).toBe(720)
		end)

		t.it("history is bounded and messages are filled in", function()
			local record = BanRecords.new(1)
			for i = 1, 30 do
				BanRecords.addHistory(record, { Type = "Kick", At = i }, 20)
			end
			expect(#record.History).toBe(20)
			expect(record.History[1].At).toBe(11)
			expect(BanRecords.countSince(record, "Kick", 25)).toBe(6)
			local text = BanRecords.format("until {until}, ref {appeal}", "ACF-XYZ", 0)
			expect(text).toBe("until 1970-01-01 00:00 UTC, ref ACF-XYZ")
			expect(BanRecords.format("{until}", "r", nil)).toBe("further notice")
		end)
	end)
end
