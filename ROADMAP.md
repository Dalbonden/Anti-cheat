# ACF Roadmap

Phases run in order. A phase starts only after the previous phase's acceptance criteria
are verified.

| Phase | Version | Status |
|-------|---------|--------|
| 1 — Core Foundation | 0.1.0 | **Done** (offline-verified; Studio run pending, see below) |
| 2 — Remote Security | 0.2.0 | **Done** (offline-verified; Studio run pending) |
| 3 — Movement & Physics | 0.3.0 | Next |
| 4 — Combat Integrity | 0.4.0 | Planned |
| 5 — Behavioural Intelligence | 0.5.0 | Planned |
| 6 — Risk Scoring & Evidence | 0.6.0 | Planned |
| 7 — Hybrid Enforcement | 0.7.0 | Planned |
| 8 — Testing & Production Release | 1.0.0 | Planned |

## Phase 1 — Core Foundation ✅

| Acceptance criterion | Verified by |
|----------------------|-------------|
| Framework initialises from validated configuration; invalid config fails with all errors | `Unit/Configuration`, `Integration/Framework` |
| Modules implement `Initialize/Start/Stop/Destroy`; definitions validated | `Unit/ModuleLoader` |
| Dependency ordering, missing/disabled/cyclic dependency handling | `Unit/ModuleLoader` |
| Explicit lifecycle state machine with published transitions | `Unit/ModuleLoader` |
| Error isolation: failing module, handler, task, sink | Unit + `ExploitSimulation/Pipeline` |
| Resource cleanup scoped to Start/Stop and Initialize/Destroy | `Unit/ModuleLoader`, `Integration/Framework` |
| Player sessions, rejoin, character generations, pre-existing players | `Integration/Framework` |
| Event bus with strict topics and recursion limit | `Unit/CorePrimitives` |
| Detection event schema, validation, sanitisation, identity binding | `Integration/Framework`, `ExploitSimulation/Pipeline` |
| Evidence infrastructure: bounded, merged, expiring, rejoin-safe | `Unit/EvidenceManager`, `ExploitSimulation/Pipeline` |
| Structured, rate-limited logging | `Unit/CorePrimitives` |
| Strict type check against Roblox definitions | `tools/check.sh` |

**Open item:** run `ServerStorage.ACFTests.Runner` inside Roblox Studio (see TESTING.md).
No Studio instance was connected when Phase 1 finished, so the suite has run under Lune
(Luau 0.10.5) but not yet in the Roblox VM.

## Phase 2 — Remote Security ✅

| Acceptance criterion | Verified by |
|----------------------|-------------|
| RemoteEvent, UnreliableRemoteEvent and RemoteFunction validation | `Integration/RemoteSecurity` |
| Argument type and structure validation with secure defaults and bounded traversal | `Unit/Validators`, `ExploitSimulation/Remotes` |
| Per-player, per-remote rate limiting and cooldowns | `Integration/RemoteSecurity`, `ExploitSimulation/Remotes` |
| Permission and ownership validation, fail-closed on errors | `Unit/Validators` (Policies), `Integration/RemoteSecurity` |
| Duplicate transaction protection with bounded memory | `Integration/RemoteSecurity`, `ExploitSimulation/Remotes` |
| Suspicious-pattern tracking; one invalid request is never reported | `ExploitSimulation/Remotes` (single, decay, laggy burst, sustained) |
| Reusable schemas usable by any game | `docs/REMOTE_SECURITY.md`; public `ACF.Validators`, `ACF.Permissions`, `ACF.Ownership` |
| Fail closed while stopped; handler errors isolated | `Integration/RemoteSecurity` |
| Measurable overhead | `tools/bench.sh` (~3 µs per accepted request under Lune) |

**Deviation:** `Shared/Protocol` moved to Phase 3. ACF creates no remotes of its own until
client telemetry exists, so a protocol module would have no consumer yet.

**Open item:** as for Phase 1, the Studio run of the suite is pending.

## Phase 3 — Movement & Physics (next)

- Server-observed sampling of character root position/velocity through the Scheduler,
  keyed by `CharacterGeneration` so respawns never create false teleports.
- Detectors: speed, flight (sustained airtime without support), noclip (raycast through
  geometry between samples), teleport anomalies, infinite jump, abnormal acceleration.
- Allowances for latency, network ownership, knockback, vehicles and seats, and
  server-authorized teleports (`ACF:AuthorizeTeleport(player, cframe)`).
- `ClientTelemetry` + `Shared/Protocol`: optional client hints, always treated as untrusted
  and protected by RemoteSecurity.
- Never act on a single sample: per-detector violation accumulators, as in Phase 2.

## Later-phase notes carried from Phase 1

- Evidence is per-server. Persisting it across servers requires the DataStore adapter
  (Phase 6) and must be batched.
- `Enforcement.*` configuration is validated but inert until Phase 7.
- `Modules.Movement = true` etc. currently warn "not available in this ACF version".
- RemoteSecurity suspicion is per remote; correlating across remotes and detectors is
  Phase 6 (RiskEngine).
