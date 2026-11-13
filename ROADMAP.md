# ACF Roadmap

Phases run in order. A phase starts only after the previous phase's acceptance criteria
are verified.

| Phase | Version | Status |
|-------|---------|--------|
| 1 — Core Foundation | 0.1.0 | **Done** (offline-verified; Studio run pending, see below) |
| 2 — Remote Security | 0.2.0 | Next |
| 3 — Movement & Physics | 0.3.0 | Planned |
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

## Phase 2 — Remote Security (next)

- Reusable argument schemas (types, ranges, string lengths, table shapes, Instance class
  and ancestry checks).
- `RemoteEvent` / `RemoteFunction` wrappers that validate before the developer's handler
  runs. RemoteFunctions never invoke the client.
- Per-player, per-remote rate limiting and cooldowns, built on `RateLimiter`.
- Permission and ownership hooks supplied by the game.
- Duplicate-transaction protection (idempotency keys with bounded memory).
- Suspicious-pattern tracking: reports go through `context:Report`. A single malformed
  request is logged at low confidence, not treated as proof.
- `Shared/Protocol` for remote naming.

## Later-phase notes carried from Phase 1

- Evidence is per-server. Persisting it across servers requires the DataStore adapter
  (Phase 6) and must be batched.
- `Enforcement.*` configuration is validated but inert until Phase 7.
- `Modules.Movement = true` etc. currently warn "not available in this ACF version".
