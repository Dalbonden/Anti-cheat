# ACF Roadmap

Phases run in order. A phase starts only after the previous phase's acceptance criteria
are verified.

**Studio status (2026-11-17):** the full suite (278/278) and live Play-mode scenarios pass
in Roblox Studio, including R6/R15 rigs, seats, ladders, terrain water, moving platforms
and accessory hits. See TESTING.md, "Studio verification log". A 50-character NPC load test and character-morph tests also pass (2026-11-19). The only
remaining check is network-level load with real clients (Phase 8).

| Phase | Version | Status |
|-------|---------|--------|
| 1 — Core Foundation | 0.1.0 | **Done** (verified offline and in Studio) |
| 2 — Remote Security | 0.2.0 | **Done** (verified offline, in Studio, and over the real network) |
| 3 — Movement & Physics | 0.3.0 | **Done** (verified offline and live in Studio) |
| 4 — Combat Integrity | 0.4.0 | **Done** (verified offline and live in Studio) |
| 5 — Behavioural Intelligence | 0.5.0 | **Done** (verified offline; Studio run pending) |
| 6 — Risk Scoring & Evidence | 0.6.0 | **Done** (verified offline; Studio/DataStore run pending) |
| 7 — Hybrid Enforcement | 0.7.0 | Next |
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

## Phase 5 — Behavioural Intelligence ✅

| Acceptance criterion | Verified by |
|----------------------|-------------|
| Per-player baselines with EMA and variance | `Unit/Statistics`, `Unit/BehavioralDetectors` (signal players) |
| CUSUM change detection over game-supplied signals | `ExploitSimulation/Behavioral` (10×, 4×, from-join, colluding); `Unit/BehavioralDetectors` (no single-bucket alarm) |
| Population baselines that the cheater cannot shift | Median baseline; colluding-exploiters test; accuracy excludes the player's own shots |
| Accuracy and headshot ratio with sample-size guards | `Unit/BehavioralDetectors` (short streaks, 80% player); `Integration/BehavioralLegit` (9,000 shots, lone strong player); `ExploitSimulation/Behavioral` (aimbot, head-lock) |
| Automation: low-variance timing, repeated invalid actions | `ExploitSimulation/Behavioral` (autoclickers, invalid floods, plus the documented limits); `Integration/BehavioralLegit` (human clicking, broke-clicking) |
| Each detector documents input, model, parameters, output and explanation | `docs/BEHAVIORAL.md`; module header comments; report `Details` |
| No false positives on legitimate play | `Integration/BehavioralLegit` (10 scenarios) |
| Tests are not vacuous | Six mutation spot checks, each caught (CHANGELOG 0.5.0) |
| Measurable overhead | `tools/bench.sh`: ~1.2 µs per `RecordSignal`, ~0.38 ms per 10 s tick for 50 players × 4 signals |

**Deviation:** the planned `Economy` module was folded into Behavioral signals. A rate
model over game-reported resource gains covers what it was meant to do.

**Bugs found in design, before shipping:**

- Counting only active buckets would have flagged players paid in lumps.
- `MinRatio` 2 would have flagged 2× gamepass owners (the mutation check confirms it).

Both fixes are in the false-positive suite.

**Open items:**
- Run the suite in Studio.
- Live check with real Combat shots from a client.

## Phase 6 — Risk Scoring and Evidence ✅

| Acceptance criterion | Verified by |
|----------------------|-------------|
| Weighted, decaying evidence model `R = min(100, Σ w·c·e^(−λt))` | `Integration/Risk` (formula to 4 decimal places), `Unit/RiskModel` |
| Confidence weighting | `Unit/RiskModel`; mutation: ignoring confidence fails 3 tests |
| Evidence expiration | `Integration/Risk` (decay lowers the band; departed users forgotten) |
| Duplicate detection suppression | `Integration/Risk` (burst counts once; 20 min of one cheat saturates in Restrict) |
| Correlation handling, no double counting | `Integration/Risk` (37.5 correlated versus 60 independent; Groups merge) |
| Session risk | `Integration/Risk` (survives rejoin) |
| Persistent risk where justified | `Integration/RiskPersistence` (only ≥ 40 saved, capped history, decays in days, failures fail safe, batching, retries, shutdown) |
| Evidence history | `GetRiskHistory`: detections, band changes, history loads, resets; bounded |
| Risk explanations | `Explanation` text and per-group `Kinds`; `Unit/RiskModel` |
| Response bands 0–19 / 20–39 / 40–59 / 60–79 / 80–100 | `Unit/RiskModel` (boundaries); configurable with validated ordering |
| Tests not vacuous | Eight mutation spot checks, each caught |
| Measurable overhead | `tools/bench.sh`: ~8 µs per detection (full pipeline); ~0.26 ms per recompute for 50 users |

**Design decision:** RiskEngine is a core service, not a module, so every module's
detections reach it and it cannot be Blocked by a module failure.

**Open items:**

- Run the suite in Studio.
- Exercise the real DataStore (`RobloxStore`) with API access enabled, including the
  `BindToClose` flush on a real shutdown.

## Later-phase notes carried from Phase 1

- Evidence records are per-server by design. Risk persists across servers as a summary
  (Phase 6); full evidence records do not.
- `Enforcement.*` configuration is validated but inert until Phase 7.
- Behavioural evidence is statistical (confidence ≤ 0.8). Phase 7 must not enforce on it alone.
- Behavioural population baselines are per server. Phase 6 persists risk, not baselines;
  cross-server baselines remain future work.
- Combat returns verdicts; applying damage stays with the game. Hit registration *rollback*
  (rewinding target positions by ping) is not implemented: tolerances scale with ping
  instead. Revisit if Phase 8 measurements show false refusals at high ping.
- Server-side movement *correction* (rubber-banding) is enforcement level 3 (Phase 7);
  Phase 3 only detects.
- RemoteSecurity suspicion is per remote; the RiskEngine (Phase 6) now correlates across
  detectors.
