# Changelog

All notable changes are documented here. ACF uses [Semantic Versioning](https://semver.org/).
Before 1.0.0, minor versions may contain breaking changes; each one is listed.

## [0.2.0] — 2026-11-13 — Phase 2: Remote Security

### Added
- Built-in `RemoteSecurity` module (enabled by default, `Category = "Remote"`):
  `ACF:ProtectEvent`, `ACF:ProtectFunction`, `ACF:FindUnprotectedRemotes`, `ACF:GetRemoteStats`.
- Request pipeline: session → rate limit → argument validation → character → cooldown →
  permission → ownership → idempotency → handler. Fails closed while stopped.
- `ACF.Validators`: number, integer, string, boolean, literal, enum, optional, union,
  custom, array, struct, map, instance, vector3, cframe. Secure defaults, bounded
  traversal, no attacker text in errors.
- `ACF.Permissions` (userIds, groupRank, all, any) and `ACF.Ownership`
  (descendantOfCharacter, descendantOf, attribute).
- Suspicion model: decaying weighted score per (player, remote, reason) that reports to
  evidence only on sustained abuse.
- `Framework:GetModule(name)` and `Framework:GetModuleState(name)`.
- Built-in module registry (`Detection/BuiltIns.luau`).
- `tools/bench.sh` hot-path benchmarks.
- 57 new tests (174 total).

### Changed
- Built-in modules are registered automatically at `Initialize`, so `RemoteSecurity` now
  appears in `GetStatus().Modules`.
- Test fakes create real Instances/Vector3/CFrame when run in Studio.

## [0.1.0] — 2026-11-13 — Phase 1: Core Foundation

### Added
- `Framework` orchestrator with the `Created → Initialized → Running ⇄ Stopped → Destroyed`
  lifecycle and atomic, retryable `Initialize`.
- `ModuleLoader`: definition validation, dependency resolution (missing, disabled and
  cyclic dependencies), explicit lifecycle state machine, `Critical` modules, error
  isolation with dependent blocking.
- `Configuration`: schema constructors (`Number`, `Boolean`, `String`, `Enum`, `Table`,
  `Map`, `Open`), all-errors validation with typo suggestions, deep-frozen values,
  per-module sections validated at registration.
- `Logger`: levels, scopes, structured fields, per-message rate limiting with suppressed
  counts, ring buffer.
- `EventBus`: strict topics, error isolation, auto-disconnect of failing handlers, dispatch
  depth limit.
- `Scheduler`: central Heartbeat-driven interval and one-shot tasks, per-task CPU stats,
  stall skipping, automatic disabling of failing tasks.
- `PlayerRegistry`: sessions with per-join SessionIds, character generations, per-session
  state and cleanup.
- `DetectionManager`: report validation, identity binding, per-detector rate limiting,
  detail sanitisation, frozen `DetectionEvent`s.
- `EvidenceManager`: per-UserId bounded evidence, duplicate merging, expiry, summaries.
- `PublicAPI` singleton (`ACF:Initialize/RegisterModule/Start/Stop/...`).
- Example module `LeaderstatRateDetector` and bootstrap script.
- 117 tests (unit, integration, exploit simulation), runnable under Lune and in Studio.
- Tooling: `tools/test.sh`, `tools/check.sh` (luau-lsp strict analysis), `tools/build.sh`,
  `tools/bootstrap-tools.sh`.
