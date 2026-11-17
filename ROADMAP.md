# ACF Roadmap

Phases run in order. A phase starts only after the previous phase's acceptance criteria
are verified.

**Studio status (2026-11-17):** the full suite (278/278) and live Play-mode scenarios pass
in Roblox Studio. See TESTING.md, "Studio verification log". Remaining Studio-only
checks: R6 rigs, seats, ladders, terrain water, moving platforms, accessory hits, and
multiplayer load.

| Phase | Version | Status |
|-------|---------|--------|
| 1 — Core Foundation | 0.1.0 | **Done** (verified offline and in Studio) |
| 2 — Remote Security | 0.2.0 | **Done** (verified offline, in Studio, and over the real network) |
| 3 — Movement & Physics | 0.3.0 | **Done** (verified offline; live R15 probe verified in Studio; R6/seats/water pending) |
| 4 — Combat Integrity | 0.4.0 | **Done** (verified offline and live in Studio) |
| 5 — Behavioural Intelligence | 0.5.0 | Next |
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

## Phase 4 — Combat Integrity ✅

| Acceptance criterion | Verified by |
|----------------------|-------------|
| Damage validation, calculated by the server | `Integration/CombatLegit` (falloff, headshots, DamageCalculator); `ExploitSimulation/Combat` (client-sent damage ignored) |
| Weapon and inventory ownership | `ExploitSimulation/Combat` (NotOwned, fabricated ids); providers fail closed |
| Fire rate and cooldowns | `ExploitSimulation/Combat` (rapid fire, cooldown bypass); `Integration/CombatLegit` (max-rate fire, bunched delivery, exact cooldown) |
| Attack distance and hit validation | `ExploitSimulation/Combat` (reach/kill aura, silent aim, spoofed origin, wall-bang) |
| Projectile validation | `ExploitSimulation/Combat` (instant hit, magic bullet, replay); `Integration/CombatLegit` (travel, gravity arc, pierce) |
| Ammunition | `ExploitSimulation/Combat` (infinite ammo, instant reload); `Integration/CombatLegit` (reload cycle, SetAmmo) |
| Ability validation | Ability kind with cooldown, range and optional target |
| Integration interfaces for game-defined rules | `API/IntegrationAPI` (DefineWeapon/Ability, providers); `examples/CombatWiring.server.luau` |
| No false positives on legitimate play | `Integration/CombatLegit` (16 scenarios, incl. high ping and moving targets) |
| Measurable overhead | `tools/bench.sh` (~16 µs per validated hit under Lune) |

Tests were checked for vacuity by mutation: disabling the origin check fails the
spoofed-origin exploit test, and zeroing the hit tolerance fails the laggy-shooter
legitimate test.

**Bug found and fixed during the phase:** projectile timing and trajectory originally
assumed a straight path to the impact. Every lobbed or angled projectile would have been
flagged `OffTrajectory`. Trajectories are now searched along the real path.

**Open items:**
- Studio validation of `RobloxPhysics.Describe`: accessory hits and NPC models.
- Running the full suite in Studio.

## Phase 5 — Behavioural Intelligence (next)

- Per-player statistical baselines with EMA and variance, and CUSUM change detection, over
  game-supplied signals: resource gain, interaction frequency, progression rate.
- Combat statistics deferred from Phase 4: accuracy and headshot ratio against population
  baselines, with sample-size guards so skilled players are not flagged.
- Automation patterns: low-variance action timing (bots), repeated invalid actions.
- Each detector documents its input, model, parameters, output and explanation, and has
  tests on both legitimate and malicious behaviour.

## Later-phase notes carried from Phase 1

- Evidence is per-server. Persisting it across servers requires the DataStore adapter
  (Phase 6) and must be batched.
- `Enforcement.*` configuration is validated but inert until Phase 7.
- `Modules.Economy = true` / `Behavioral = true` currently warn "not available in this ACF version".
- Combat returns verdicts; applying damage stays with the game. Hit registration *rollback*
  (rewinding target positions by ping) is not implemented: tolerances scale with ping
  instead. Revisit if Phase 8 measurements show false refusals at high ping.
- Server-side movement *correction* (rubber-banding) is enforcement level 3 (Phase 7);
  Phase 3 only detects.
- RemoteSecurity suspicion is per remote; correlating across remotes and detectors is
  Phase 6 (RiskEngine).
