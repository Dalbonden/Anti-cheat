# Changelog

All notable changes are documented here. ACF uses [Semantic Versioning](https://semver.org/).
Before 1.0.0, minor versions may contain breaking changes; each one is listed.

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
