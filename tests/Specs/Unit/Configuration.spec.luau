local ACF = game:GetService("ServerScriptService").ACF
local Configuration = require(ACF.Core.Configuration)
local DefaultConfig = require(ACF.Core.DefaultConfig)

local S = Configuration.Schema

local function load(overrides)
	local config = Configuration.new(DefaultConfig())
	local ok, errors = config:Load(overrides)
	return config, ok, errors
end

local function joined(errors)
	return table.concat(errors, "\n")
end

return function(t)
	local expect = t.expect

	t.describe("Configuration", function()
		t.it("loads defaults with no overrides", function()
			local config, ok = load(nil)
			expect(ok).toBe(true)
			expect(config:Get("LogLevel")).toBe("Info")
			expect(config:Get("Evidence.MaxRecordsPerPlayer")).toBe(64)
			expect(config:Get("Enforcement.AutoBan")).toBe(false)
		end)

		t.it("applies valid overrides", function()
			local config, ok = load({ Debug = true, Evidence = { MaxRecordsPerPlayer = 10 }, Modules = { Movement = false } })
			expect(ok).toBe(true)
			expect(config:Get("Debug")).toBe(true)
			expect(config:Get("Evidence.MaxRecordsPerPlayer")).toBe(10)
			expect(config:Get("Evidence.RetentionSeconds")).toBe(1800)
			expect(config:Get("Modules").Movement).toBe(false)
		end)

		t.it("accepts the documented illustrative configuration", function()
			local _, ok, errors = load({
				Debug = false,
				Enforcement = { Mode = "Hybrid", AutoKick = true, AutoBan = false, ShadowMode = false },
				Modules = { Movement = true, Physics = true, RemoteSecurity = true, Combat = true, Behavioral = true },
			})
			expect(joined(errors)).toBe("")
			expect(ok).toBe(true)
		end)

		t.it("reports unknown keys with a suggestion", function()
			local _, ok, errors = load({ Enforcment = {} })
			expect(ok).toBe(false)
			expect(joined(errors)).toContain("Enforcment: unknown configuration key (did you mean 'Enforcement'?)")
		end)

		t.it("collects every error instead of stopping at the first", function()
			local _, ok, errors = load({
				LogLevel = "Verbose",
				Evidence = { MaxRecordsPerPlayer = 0, RetentionSeconds = "long" },
				Enforcement = { Mode = "hybrid" },
			})
			expect(ok).toBe(false)
			expect(#errors).toBe(4)
			local text = joined(errors)
			expect(text).toContain("LogLevel: expected one of")
			expect(text).toContain("Evidence.MaxRecordsPerPlayer: 0 is below the minimum of 1")
			expect(text).toContain("Evidence.RetentionSeconds: expected a finite number")
			expect(text).toContain("(did you mean 'Hybrid'?)")
		end)

		t.it("rejects NaN, infinity and non-integers where integers are required", function()
			local _, ok, errors = load({
				Evidence = { RetentionSeconds = 0 / 0, DuplicateWindowSeconds = math.huge, MaxRecordsPerPlayer = 2.5 },
			})
			expect(ok).toBe(false)
			expect(#errors).toBe(3)
		end)

		t.it("rejects a non-table configuration", function()
			local _, ok, errors = load("yes" :: any)
			expect(ok).toBe(false)
			expect(joined(errors)).toContain("must be a table")
		end)

		t.it("freezes resolved values", function()
			local config = load({})
			local evidence = config:Get("Evidence")
			expect(table.isfrozen(evidence)).toBe(true)
			expect(function()
				evidence.MaxRecordsPerPlayer = 1
			end).toThrow()
		end)

		t.it("is not mutated by later changes to the caller's table", function()
			local overrides = { ModuleSettings = { Mine = { Limit = 5 } } }
			local config = load(overrides)
			overrides.ModuleSettings.Mine.Limit = 999
			config:Extend("ModuleSettings", "Mine", S.Table({ Limit = S.Number(1) }))
			expect(config:Get("ModuleSettings.Mine.Limit")).toBe(5)
		end)

		t.it("validates module sections when the module extends them", function()
			local config, ok = load({ ModuleSettings = { Speed = { MaxSpeed = -1 } } })
			expect(ok).toBe(true)
			local extended, errors = config:Extend("ModuleSettings", "Speed", S.Table({ MaxSpeed = S.Number(16, { Min = 0 }) }))
			expect(extended).toBe(false)
			expect(joined(errors)).toContain("ModuleSettings.Speed.MaxSpeed")
		end)

		t.it("provides defaults for modules without user settings", function()
			local config = load({})
			local ok = config:Extend("ModuleSettings", "Speed", S.Table({ MaxSpeed = S.Number(16) }))
			expect(ok).toBe(true)
			expect(config:Get("ModuleSettings.Speed.MaxSpeed")).toBe(16)
			expect(config:Get("ModuleSettings").Speed.MaxSpeed).toBe(16)
		end)

		t.it("reports module settings no module claimed", function()
			local config = load({ ModuleSettings = { Sped = { MaxSpeed = 1 } } })
			expect(config:UnclaimedKeys()).toEqual({ "ModuleSettings.Sped" })
		end)

		t.it("refuses to load twice or claim a key twice", function()
			local config = load({})
			expect(function()
				config:Load({})
			end).toThrow("already been loaded")
			config:Extend("ModuleSettings", "A", S.Table({}))
			expect(function()
				config:Extend("ModuleSettings", "A", S.Table({}))
			end).toThrow("already been claimed")
		end)

		t.it("validates schema defaults at construction", function()
			expect(function()
				S.Number(5, { Max = 1 })
			end).toThrow("above Max")
			expect(function()
				S.Enum({ "A" }, "B")
			end).toThrow("one of its values")
		end)

		t.it("merges map entries over map defaults", function()
			local config = Configuration.new(S.Table({ Flags = S.Map(S.Boolean(false), { A = true }) }))
			local ok = config:Load({ Flags = { B = true } })
			expect(ok).toBe(true)
			expect(config:Get("Flags")).toEqual({ A = true, B = true })
		end)

		t.it("rejects cyclic tables in open sections without hanging", function()
			local cyclic = {}
			cyclic.self = cyclic
			local _, ok, errors = load({ ModuleSettings = { X = cyclic } })
			expect(ok).toBe(false)
			expect(joined(errors)).toContain("too deep")
		end)
	end)
end
