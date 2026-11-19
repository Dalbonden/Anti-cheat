# ACF — Anti-Cheat Framework for Roblox

ACF is a modular, server-authoritative anti-cheat framework for Roblox experiences. It gives
detection modules a common lifecycle, a validated configuration system, a player session
registry, an event bus, a central scheduler and a bounded evidence store, so each detector
only has to implement its own detection logic.

> **Status: v0.5.0 — Phases 1–5 (Core, Remote Security, Movement & Physics, Combat,
> Behavioural Intelligence).** The framework core, remote validation, server-observed
> movement/physics detection, server-authoritative combat and statistical behaviour
> detection are complete and tested. Phases 1–4 are also verified live in Roblox Studio.
> Risk scoring and enforcement arrive in later phases. See [ROADMAP.md](ROADMAP.md). In this
> version ACF validates requests, authorizes combat and records evidence. It does **not**
> kick, ban, or correct anyone.

**Principle: never trust the client.** ACF runs entirely on the server. Nothing in
`ServerScriptService.ACF` replicates to clients.

## Installation

**With Rojo:** add this repository's `src/` to your project, mapping:

| Path            | DataModel location                 |
|-----------------|------------------------------------|
| `src/Server`    | `ServerScriptService.ACF`          |
| `src/Shared`    | `ReplicatedStorage.ACFShared`      |
| `src/Client/ClientTelemetry.client.luau` | `StarterPlayer.StarterPlayerScripts.ACFTelemetry` (optional; only used with `Modules.Telemetry = true`) |

`default.project.json` shows the mapping (serve port 34877).

**Without Rojo:** run `tools/build.sh` and open `build/ACF.rbxl`. Copy `ServerScriptService.ACF`
and `ReplicatedStorage.ACFShared` into your place.

## Quick start

```lua
-- ServerScriptService/ACFBootstrap (Script)
local ACF = require(game:GetService("ServerScriptService").ACF)

ACF:Initialize({
    LogLevel = "Info",
    Enforcement = { Mode = "Hybrid", AutoKick = true, AutoBan = false, ShadowMode = true },
    ModuleSettings = {
        LeaderstatRate = { StatName = "Coins", MaxGainPerSecond = 50 },
    },
})

ACF:RegisterModule(require(path.to.LeaderstatRateDetector).new(ACF.Schema))

local V = ACF.Validators
ACF:ProtectEvent(game.ReplicatedStorage.Remotes.BuyItem, {
    Arguments = { V.string({ MaxLength = 32 }), V.integer({ Min = 1, Max = 99 }) },
    RateLimit = { Burst = 5, PerSecond = 1 },
    Handler = function(player, itemId, quantity) --[[ validated ]] end,
})

ACF:OnDetection(function(payload)
    print(payload.Event.Detector, payload.Event.Kind, payload.Event.UserId)
end)

ACF:Start()
```

Invalid configuration fails at `Initialize` and lists every problem, with suggestions for typos:

```
ACF configuration is invalid:
  - Enforcment: unknown configuration key (did you mean 'Enforcement'?)
  - Evidence.MaxRecordsPerPlayer: 0 is below the minimum of 1
```

## Documentation

| Document | Contents |
|----------|----------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Subsystems, data flow, placement, design decisions |
| [docs/API.md](docs/API.md) | Public API reference |
| [docs/REMOTE_SECURITY.md](docs/REMOTE_SECURITY.md) | Protecting RemoteEvents/Functions, validators, suspicion model |
| [docs/MOVEMENT.md](docs/MOVEMENT.md) | Movement, physics and telemetry detectors, allowances |
| [docs/COMBAT.md](docs/COMBAT.md) | Weapons, abilities, server-authorized hits and damage |
| [docs/BEHAVIORAL.md](docs/BEHAVIORAL.md) | Statistical detection: income signals, accuracy, autoclickers, invalid actions |
| [docs/MODULES.md](docs/MODULES.md) | Writing detection modules, with a worked example |
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | Every configuration key |
| [DEVELOPMENT.md](DEVELOPMENT.md) | Toolchain, layout, conventions |
| [TESTING.md](TESTING.md) | Running tests offline and in Studio |
| [ROADMAP.md](ROADMAP.md) | Phases and milestones |
| [CHANGELOG.md](CHANGELOG.md) | Release history |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Common problems |

## Development in 30 seconds

```bash
tools/bootstrap-tools.sh   # once: rojo, lune, luau-lsp into .bin/
tools/test.sh              # 334 tests, offline, ~3s
tools/check.sh             # strict type check against Roblox definitions
tools/bench.sh             # hot-path micro-benchmarks
tools/build.sh             # build/ACF.rbxl and build/ACF-Tests.rbxl
```

## License

Not yet specified by the project owner.
