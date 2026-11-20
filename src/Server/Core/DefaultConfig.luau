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

		-- Graduated enforcement (Phase 7). See docs/ENFORCEMENT.md.
		Enforcement = S.Table({
			-- Hybrid: levels 0-4 automatic, kicks/bans automatic only when corroborated
			-- and allowed below. Manual: levels 0-4 automatic, kicks/bans need staff.
			-- Off: logging only.
			Mode = S.Enum({ "Hybrid", "Manual", "Off" }, "Hybrid"),
			AutoKick = S.Boolean(true),
			AutoBan = S.Boolean(false),
			-- Decide and audit everything, apply nothing.
			ShadowMode = S.Boolean(false),
			-- Level applied automatically per risk band (0 log, 1 monitor, 2 reject,
			-- 3 correct, 4 temporary restriction).
			BandLevels = S.Table({
				Normal = S.Number(0, { Min = 0, Max = 4, Integer = true }),
				Increased = S.Number(1, { Min = 0, Max = 4, Integer = true }),
				Restrict = S.Number(2, { Min = 0, Max = 4, Integer = true }),
				Investigation = S.Number(3, { Min = 0, Max = 4, Integer = true }),
				EnforcementReview = S.Number(4, { Min = 0, Max = 4, Integer = true }),
			}),
			-- A risk group at or above this score becomes a restriction tag.
			TagMinScore = S.Number(15, { Min = 0, Max = 100 }),
			-- Groups built only from statistical detectors. Never sufficient alone.
			StatisticalGroups = S.Map(S.Boolean(true), { Aim = true, Economy = true, Automation = true }),
			-- Corroboration needed before any automatic kick or ban.
			Corroboration = S.Table({
				MinConfidence = S.Number(0.9, { Min = 0, Max = 1 }),
				MinIndependentGroups = S.Number(2, { Min = 1, Max = 10, Integer = true }),
				-- One non-statistical group this strong is enough on its own.
				HardEvidenceMinScore = S.Number(40, { Min = 0, Max = 100 }),
			}),
			TemporaryRestrictionSeconds = S.Number(600, { Min = 10, Max = 86400 }),
			Correction = S.Table({
				Enabled = S.Boolean(true),
				CooldownSeconds = S.Number(1, { Min = 0.1, Max = 60 }),
				MaxDistance = S.Number(200, { Min = 1, Max = 100000 }),
			}),
			Bans = S.Table({
				DataStoreName = S.String("ACF_Bans_v1", { MaxLength = 50 }),
				CheckOnJoin = S.Boolean(true),
				UseRobloxBanApi = S.Boolean(true),
				TempBanHours = S.Number(24, { Min = 0.01, Max = 8760 }),
				EscalationFactor = S.Number(2, { Min = 1, Max = 10 }),
				MaxTempBanHours = S.Number(720, { Min = 0.01, Max = 87600 }),
				KicksBeforeTempBan = S.Number(2, { Min = 1, Max = 100, Integer = true }),
				TempBansBeforePermanentProposal = S.Number(2, { Min = 1, Max = 100, Integer = true }),
				RepeatWindowDays = S.Number(7, { Min = 0.01, Max = 3650 }),
				RequireApprovalForPermanentBan = S.Boolean(true),
				MaxHistory = S.Number(20, { Min = 1, Max = 200, Integer = true }),
				FlushIntervalSeconds = S.Number(5, { Min = 1, Max = 3600 }),
				MaxAttempts = S.Number(5, { Min = 1, Max = 20, Integer = true }),
			}),
			Cases = S.Table({
				MaxOpen = S.Number(200, { Min = 1, Max = 10000, Integer = true }),
				ExpiryHours = S.Number(72, { Min = 0.01, Max = 8760 }),
			}),
			Audit = S.Table({
				MaxEntries = S.Number(500, { Min = 10, Max = 100000, Integer = true }),
				-- Repeated rejections/corrections of one user and kind are summarised.
				RepeatIntervalSeconds = S.Number(60, { Min = 0, Max = 3600 }),
			}),
			Messages = S.Table({
				Kick = S.String("You were removed by the server's anti-cheat. Appeal reference: {appeal}", { MaxLength = 400 }),
				TempBan = S.String("You are banned until {until}. Appeal reference: {appeal}", { MaxLength = 400 }),
				PermanentBan = S.String("You are banned. Appeal reference: {appeal}", { MaxLength = 400 }),
			}),
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

		-- Centralised risk (Phase 6). See docs/RISK.md.
		Risk = S.Table({
			Enabled = S.Boolean(true),
			-- Evidence half-life: lambda = ln 2 / HalfLifeSeconds.
			HalfLifeSeconds = S.Number(600, { Min = 10, Max = 86400 }),
			-- Repeats of one (Detector, Kind) saturate at Severity x Confidence x RepeatCap.
			RepeatCap = S.Number(2, { Min = 1, Max = 20 }),
			-- Repeats of one kind closer together than this are not added again.
			RepeatSuppressSeconds = S.Number(5, { Min = 0, Max = 3600 }),
			-- Weight of non-strongest kinds inside one correlation group.
			SecondaryWeight = S.Number(0.25, { Min = 0, Max = 1 }),
			RecomputeIntervalSeconds = S.Number(5, { Min = 0.5, Max = 3600 }),
			MaxKeysPerUser = S.Number(64, { Min = 4, Max = 1024, Integer = true }),
			MaxHistory = S.Number(50, { Min = 1, Max = 1000, Integer = true }),
			-- Lower bounds of the response bands (must increase).
			Bands = S.Table({
				Increased = S.Number(20, { Min = 0, Max = 100 }),
				Restrict = S.Number(40, { Min = 0, Max = 100 }),
				Investigation = S.Number(60, { Min = 0, Max = 100 }),
				EnforcementReview = S.Number(80, { Min = 0, Max = 100 }),
			}),
			-- Correlation groups: "Detector.Kind", Detector or Category -> group name.
			-- Unlisted detections use their Category as the group.
			Groups = S.Map(S.String("", { MaxLength = 64 }), {
				Physics = "Movement",
				["Behavioral.AccuracyAnomaly"] = "Aim",
				["Behavioral.HeadshotAnomaly"] = "Aim",
				["Behavioral.SignalAnomaly"] = "Economy",
				["Behavioral.SignalRateLimit"] = "Economy",
				["Behavioral.RegularTiming"] = "Automation",
				["Behavioral.RepeatedInvalidActions"] = "Automation",
			}),
			-- Risk carried between sessions (DataStore). Off unless the game opts in.
			Persistence = S.Table({
				Enabled = S.Boolean(false),
				DataStoreName = S.String("ACF_Risk_v1", { MaxLength = 50 }),
				-- Only sessions ending at or above this risk are saved.
				MinRiskToSave = S.Number(40, { Min = 0, Max = 100 }),
				-- Saved risk x Weight x 0.5^(hours / HalfLifeHours), capped, seeds a session.
				Weight = S.Number(0.5, { Min = 0, Max = 1 }),
				HalfLifeHours = S.Number(24, { Min = 0.1, Max = 8760 }),
				Cap = S.Number(35, { Min = 0, Max = 100 }),
				FlushIntervalSeconds = S.Number(30, { Min = 1, Max = 3600 }),
				MaxWritesPerFlush = S.Number(10, { Min = 1, Max = 100, Integer = true }),
				MaxAttempts = S.Number(3, { Min = 1, Max = 10, Integer = true }),
				-- Session summaries kept in the saved record.
				MaxSessions = S.Number(5, { Min = 1, Max = 50, Integer = true }),
			}),
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
