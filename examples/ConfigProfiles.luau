--!strict
--[[
	Example configurations for common kinds of game. Start from the closest one and tune.
	Every profile is booted by tests/Specs/Unit/ConfigProfiles.spec.luau, so a key that no
	longer exists fails the test suite rather than an upgrade.

		local Profiles = require(path.to.ConfigProfiles)
		ACF:Initialize(Profiles.Shooter)

	All profiles start in shadow mode: ACF decides and audits, nothing automatic is
	applied. Turn ShadowMode off once the audit log looks right (RELEASING.md).
]]

local Profiles = {}

-- Competitive shooter: hitscan/projectile combat is the main attack surface.
Profiles.Shooter = {
	Enforcement = { Mode = "Hybrid", AutoKick = true, AutoBan = false, ShadowMode = true },
	ModuleSettings = {
		Combat = {
			-- Fast-moving targets and long sight lines: a little more room for lag.
			HitToleranceStuds = 8,
			MaxTargetSpeed = 40,
		},
		Behavioral = {
			-- Large hitboxes make high accuracy normal in some shooters; tune per game.
			Accuracy = { AccuracyFloor = 0.92 },
		},
	},
}

-- Simulator / tycoon: the economy is what exploiters attack.
Profiles.Simulator = {
	Enforcement = { Mode = "Hybrid", AutoKick = true, AutoBan = false, ShadowMode = true },
	ModuleSettings = {
		Behavioral = {
			Signals = {
				-- Gamepasses up to 3x are common; record amounts before multipliers or
				-- raise this.
				MinRatio = 4,
			},
			Actions = {
				-- Clicker games: judge regularity over longer windows.
				WindowSize = 40,
			},
		},
	},
	-- Repeat offenders across servers: carry risk between sessions.
	Risk = { Persistence = { Enabled = true } },
}

-- Obby / platformer: double jumps, dashes and launch pads.
-- (Grant dashes and pads with ACF:AllowMovement, and server teleports with AuthorizeTeleport.)
Profiles.Platformer = {
	Enforcement = { Mode = "Hybrid", AutoKick = true, AutoBan = false, ShadowMode = true },
	ModuleSettings = {
		Movement = {
			MaxAirJumps = 1,
			SpeedTolerance = 1.35,
		},
	},
}

-- Roleplay / social: low stakes; staff decide every removal, ACF only restricts.
Profiles.Roleplay = {
	Enforcement = { Mode = "Manual", AutoKick = false, AutoBan = false, ShadowMode = true },
	Modules = { Combat = false },
}

-- Watching only: everything detected and scored, no automatic action of any kind.
Profiles.ObserveOnly = {
	Enforcement = { Mode = "Off" },
	LogLevel = "Info",
}

return Profiles
