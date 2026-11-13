# ACF Roadmap

Phases run in order. A phase starts only after the previous phase's acceptance criteria
are verified.

| Phase | Version | Status |
|-------|---------|--------|
| 1 — Core Foundation | 0.1.0 | **Done** (offline-verified; Studio run pending, see below) |
| 2 — Remote Security | 0.2.0 | **Done** (offline-verified; Studio run pending) |
| 3 — Movement & Physics | 0.3.0 | **Done** (offline-verified; Studio run pending) |
| 4 — Combat Integrity | 0.4.0 | Next |
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

## Phase 3 — Movement & Physics ✅

| Acceptance criterion | Verified by |
|----------------------|-------------|
| Speed, flight, noclip, teleport, infinite jump, abnormal acceleration | `ExploitSimulation/Movement` |
| Unexpected velocity and physics manipulation (fling, extreme velocity, tp-walk mismatch) | `ExploitSimulation/Movement` (physics) |
| Latency, freezes and packet bunching | `Integration/MovementLegit` (1.5 s / 3 s freezes, jittery high ping), `Unit/MovementDetectors` (time credit) |
| Knockback, vehicles, custom mechanics, server teleports | `Integration/MovementLegit` (Impulse, seated vehicle, dash, AuthorizeTeleport) |
| Respawning and character replacement | `Integration/MovementLegit` (respawn far away; death ragdoll) |
| Moving platforms, climbing, swimming, falling, double-jump games | `Integration/MovementLegit` |
| Never punish a single position update | `ExploitSimulation/Movement` (single teleport not reported), `Unit/MovementDetectors` (ViolationTracker) |
| Configurable physical constraints | `ModuleSettings.Movement` / `.Physics`, per-detector enable flags |
| Measurable overhead | `tools/bench.sh` (~0.56 ms per tick for 50 players under Lune) |

Also delivered:

- `Shared/Protocol` and the optional `Telemetry` module with its client script (weak signal,
  off by default).
- The shared `Intelligence/ViolationTracker`. RemoteSecurity was refactored onto it, so
  detectors no longer duplicate suspicion logic.

**Network ownership.** Characters are client-owned, so every detector assumes the client
controls its own physics and judges only server-observed results. Explicit ownership
checks on world parts are not included; they are game-specific and expensive.

**Open items:**

- Run the Studio suite.
- Validate `RobloxPhysics` (the real probe) in Studio: R6/R15 clearance, seats, ladders,
  terrain water, platform `GroundSpeed`. This is the main Phase 3 risk, because the real
  probe has no offline test.

## Phase 4 — Combat Integrity (next)

- An integration API for games to declare weapons, abilities and their rules (damage
  range, fire rate, range, ammo, cooldowns).
- Server-authorized damage: validated hit requests (built on RemoteSecurity), with
  distance and line-of-sight checks via `Environment.Physics:Cast`.
- Fire-rate and cooldown enforcement per weapon and ability; ammunition and inventory
  ownership; projectile validation (speed, travel time, origin near the shooter).
- Hit-pattern violations through ViolationTracker (impossible accuracy belongs to
  Phase 5 statistics).

## Later-phase notes carried from Phase 1

- Evidence is per-server. Persisting it across servers requires the DataStore adapter
  (Phase 6) and must be batched.
- `Enforcement.*` configuration is validated but inert until Phase 7.
- `Modules.Combat = true` etc. currently warn "not available in this ACF version".
- Server-side movement *correction* (rubber-banding) is enforcement level 3 (Phase 7);
  Phase 3 only detects.
- RemoteSecurity suspicion is per remote; correlating across remotes and detectors is
  Phase 6 (RiskEngine).
