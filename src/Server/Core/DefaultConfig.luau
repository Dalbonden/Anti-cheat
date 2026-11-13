--!strict
--[[
	Root configuration schema with defaults. See docs/CONFIGURATION.md for the meaning of
	each setting. Values marked "(Phase N)" are validated now but have no effect until
	that phase's subsystem ships; this keeps the public configuration shape stable.
]]

local Configuration = require(script.Parent.Configuration)

local S = Configuration.Schema

return function(): Configuration.SchemaNode
	return S.Table({
		Debug = S.Boolean(false, "Forces LogLevel to Debug."),
		LogLevel = S.Enum({ "Debug", "Info", "Warn", "Error" }, "Info"),

		Logging = S.Table({
			BufferSize = S.Number(500, { Min = 16, Max = 10000, Integer = true }),
			RateLimitBurst = S.Number(20, { Min = 1, Max = 1000, Integer = true }),
			RateLimitWindowSeconds = S.Number(10, { Min = 0.1, Max = 3600 }),
		}),

		-- (Phase 7) Enforcement policy. Validated now; not acted on until Phase 7.
		Enforcement = S.Table({
			Mode = S.Enum({ "Hybrid", "Manual", "Off" }, "Hybrid"),
			AutoKick = S.Boolean(true),
			AutoBan = S.Boolean(false),
			ShadowMode = S.Boolean(false),
		}),

		-- Enable or disable modules by name. Modules not listed use their own
		-- EnabledByDefault (true unless the module says otherwise).
		Modules = S.Map(S.Boolean(true)),

		-- Per-module settings, validated against each module's ConfigSchema when the
		-- module registers.
		ModuleSettings = S.Open(),

		Detection = S.Table({
			-- Token bucket per (player, detector): sustained reports per second...
			ReportsPerSecond = S.Number(10, { Min = 0.1, Max = 1000 }),
			-- ...and the burst allowed above that rate.
			ReportBurst = S.Number(30, { Min = 1, Max = 10000, Integer = true }),
			MaxDetailKeys = S.Number(32, { Min = 0, Max = 256, Integer = true }),
			MaxDetailStringLength = S.Number(256, { Min = 8, Max = 4096, Integer = true }),
		}),

		Evidence = S.Table({
			MaxRecordsPerPlayer = S.Number(64, { Min = 1, Max = 1024, Integer = true }),
			-- Records not seen again within this long are pruned.
			RetentionSeconds = S.Number(1800, { Min = 1, Max = 86400 }),
			-- Identical (detector, kind) detections within this window merge into one record.
			DuplicateWindowSeconds = S.Number(5, { Min = 0, Max = 3600 }),
			PruneIntervalSeconds = S.Number(30, { Min = 1, Max = 3600 }),
		}),

		Scheduler = S.Table({
			MaxConsecutiveFailures = S.Number(5, { Min = 1, Max = 1000, Integer = true }),
		}),

		EventBus = S.Table({
			MaxHandlerFailures = S.Number(10, { Min = 1, Max = 1000, Integer = true }),
			MaxDispatchDepth = S.Number(8, { Min = 1, Max = 64, Integer = true }),
		}),
	})
end
