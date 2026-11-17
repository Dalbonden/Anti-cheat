# Developing ACF

## Toolchain

All tools live in `.bin/` (git-ignored). `tools/bootstrap-tools.sh` downloads pinned versions:

| Tool | Version | Use |
|------|---------|-----|
| Rojo | 7.7.0 | Sync to Studio (`rojo serve`, port 34877 / tests 34878), build place files, sourcemaps |
| Lune | 0.10.5 | Runs the test suite outside Roblox |
| luau-lsp | 1.70.1 | `analyze` = strict type checking against Roblox definitions |

Scripts are POSIX shell (Git Bash on Windows).

## Repository layout

```
src/Server/            → ServerScriptService.ACF (init.luau returns the PublicAPI)
  Types.luau             shared server types
  Core/                  Framework, ModuleLoader, Configuration, Logger, EventBus,
                         Scheduler, PlayerRegistry, Cleanup, RateLimiter, Topics, DefaultConfig
  Detection/             DetectionManager, BuiltIns registry
    RemoteSecurity/      RemoteSecurity module, Validators, Policies
    Movement/            Movement module + pure MovementDetectors
    Physics/             Physics module
    Combat/              Combat module + pure CombatRules
    Telemetry/           optional heartbeat module
  Intelligence/          EvidenceManager, ViolationTracker (+ RiskEngine etc. in Phase 6)
  Platform/              RobloxEnvironment, RobloxPhysics (the only Roblox-service code)
  API/                   PublicAPI, IntegrationAPI (game-defined rules)
src/Shared/            → ReplicatedStorage.ACFShared: Constants, Protocol (client-visible; keep it harmless)
src/Client/            → StarterPlayerScripts.ACFTelemetry (optional heartbeat; untrusted)
examples/              → ServerStorage.ACFExamples in the test place
tests/Specs/           → ServerStorage.ACFTests (portable specs + TestKit, Fakes, Runner)
tests/lune/            Lune-only harness (virtual DataModel)
tools/                 test / check / bench / build / bootstrap scripts; verify = pre-commit gate
docs/                  API, module authoring, configuration, troubleshooting
```

## Conventions

- `--!strict` in every source file. `tools/check.sh` must report no errors.
- Require with `script.Parent...`, never by string path. This keeps the source compatible
  with every Studio version and with the Lune harness.
- Never call `game:GetService` for platform services outside `Platform/`. Take them from the
  `Environment` instead.
- Raise on developer error (bad config, bad definitions, wrong state). Isolate and log runtime
  faults; never let them escape into the framework.
- Log messages are constant strings. Variable data goes in fields, because rate limiting
  keys on scope + message.
- Every per-player or per-key structure must have an explicit bound and a release path.
- New behaviour ships with tests, including at least one adversarial case where relevant.
- Never log or embed attacker-supplied strings in messages; describe types and lengths.
- Guard Debug logging on hot paths with `Logger:IsEnabled("Debug")`.
- Detectors emit weighted violations into a `ViolationTracker`; never call
  `context:Report` straight from a single observation.
- Keep detector maths pure (plain numbers in, violations out). Roblox access belongs in
  `Platform/`.
- Update CHANGELOG.md, ROADMAP.md and the relevant docs in the same change.

## Before every commit

Run `tools/verify.sh` and commit only if it prints `VERIFY OK`. It stops at the first
failing step, so a failed type check can never slip through a command chain.

## Workflow per phase

1. Inspect the current code and docs. 2. Plan. 3. Implement. 4. `tools/test.sh`.
5. `tools/check.sh`. 6. Review for architectural problems. 7. Fix. 8. Update docs.
9. Summarise completed and remaining work in ROADMAP.md.

## Versioning

- SemVer; `src/Shared/Constants.luau` `VERSION` is the single source of truth.
- Each phase bumps the minor version until 1.0.0.
- Release channels (dev / canary / stable) are introduced in Phase 8.
