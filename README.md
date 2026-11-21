# ACF — Anti-Cheat Framework for Roblox

ACF is a modular, server-authoritative anti-cheat framework for Roblox experiences. It gives
detection modules a common lifecycle, a validated configuration system, a player session
registry, an event bus, a central scheduler and a bounded evidence store, so each detector
only has to implement its own detection logic.

> **Status: v1.0.0 release candidate. All 8 phases are complete.** 420 tests pass offline
> and inside Roblox Studio's VM. A population evaluation (docs/EVALUATION.md) covering
> 50 honest player-hours found no false positives, and every cheat type was caught.
> Live Studio checks covered movement correction against a client-side teleport,
> 790 ms network latency, kicks, and DataStore failure.
>
> **Ships on the canary channel.** Stable 1.0.0 is promoted after a canary period in
> real servers ([RELEASING.md](RELEASING.md)), because multi-client load and the live
> Roblox ban API can only be verified in a published game.
>
> **ACF now enforces.** With the defaults it restricts suspicious players, corrects
> movement, and kicks automatically only on corroborated, non-statistical evidence.
> Bans need `AutoBan` or staff approval; permanent bans always need approval. **Start
> with `Enforcement = { ShadowMode = true }`** and read [docs/ENFORCEMENT.md](docs/ENFORCEMENT.md).

**Principle: never trust the client.** ACF runs entirely on the server. Nothing in
`ServerScriptService.ACF` replicates to clients.

## Installation

**From a release (recommended):** take `ACF-<version>.rbxm` from a release
([RELEASING.md](RELEASING.md)). Drag the contents of its three folders into
ServerScriptService, ReplicatedStorage and StarterPlayer → StarterPlayerScripts.
[docs/INTEGRATION.md](docs/INTEGRATION.md) walks through wiring it into a game, and
[docs/MIGRATION.md](docs/MIGRATION.md) covers upgrading from an older version.

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
| [docs/INTEGRATION.md](docs/INTEGRATION.md) | **Start here:** wiring ACF into a game, step by step, with a checklist |
| [docs/MIGRATION.md](docs/MIGRATION.md) | Upgrading between versions: behaviour changes and what to do |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Subsystems, data flow, placement, design decisions |
| [docs/API.md](docs/API.md) | Public API reference |
| [docs/REMOTE_SECURITY.md](docs/REMOTE_SECURITY.md) | Protecting RemoteEvents/Functions, validators, suspicion model |
| [docs/MOVEMENT.md](docs/MOVEMENT.md) | Movement, physics and telemetry detectors, allowances |
| [docs/COMBAT.md](docs/COMBAT.md) | Weapons, abilities, server-authorized hits and damage |
| [docs/BEHAVIORAL.md](docs/BEHAVIORAL.md) | Statistical detection: income signals, accuracy, autoclickers, invalid actions |
| [docs/RISK.md](docs/RISK.md) | Risk score, bands, correlation, persistent risk, explanations |
| [docs/ENFORCEMENT.md](docs/ENFORCEMENT.md) | Levels 0–7, shadow mode, cases and approvals, bans, appeals, audit log |
| [docs/MODULES.md](docs/MODULES.md) | Writing detection modules, with a worked example |
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | Every configuration key |
| [DEVELOPMENT.md](DEVELOPMENT.md) | Toolchain, layout, conventions |
| [TESTING.md](TESTING.md) | Running tests offline and in Studio |
| [ROADMAP.md](ROADMAP.md) | Phases and milestones |
| [docs/EVALUATION.md](docs/EVALUATION.md) | Measured detection accuracy, false positives, CPU, memory, logging |
| [RELEASING.md](RELEASING.md) | Release channels, canary rollout, promotion criteria |
| [CHANGELOG.md](CHANGELOG.md) | Release history |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Common problems |

## Development in 30 seconds

```bash
tools/bootstrap-tools.sh   # once: rojo, lune, luau-lsp into .bin/
tools/test.sh              # 426 tests, offline, ~10s
tools/evaluate.sh quick    # population evaluation (accuracy, false positives, CPU, memory)
tools/check.sh             # strict type check against Roblox definitions
tools/bench.sh             # hot-path micro-benchmarks
tools/build.sh             # build/ACF.rbxl and build/ACF-Tests.rbxl
```

## License

Not yet specified by the project owner.
