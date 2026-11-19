# Changelog

All notable changes are documented here. ACF uses [Semantic Versioning](https://semver.org/).
Before 1.0.0, minor versions may contain breaking changes; each one is listed.

## [0.5.0] — 2026-11-19 — Phase 5: Behavioural Intelligence

### Added
- Built-in `Behavioral` module (on by default), documented in docs/BEHAVIORAL.md:
  - **Signals** (`ACF:DefineSignal`, `ACF:RecordSignal`): per-player resource and
    progression rates. A robust median-player population baseline, or a game-defined
    one, feeds a clamped CUSUM. `SignalAnomaly` needs both a CUSUM alarm and ≥ 3× the
    baseline. `MaxPerSecond` adds a hard limit (`SignalRateLimit`).
  - **Accuracy and headshots** from Combat's validated shots: Wilson lower bounds
    against the server's own ratio for that weapon, excluding the player, with
    absolute floors (`AccuracyAnomaly`, `HeadshotAnomaly`).
  - **Actions** (`ACF:RecordAction`): machine-regular timing (`RegularTiming`) and
    sustained invalid actions (`RepeatedInvalidActions`).
  - `ACF:GetBehaviorProfile(player)` and `ACF:GetBehaviorStats()`.
- `Intelligence/Statistics`: pure EWMA, CUSUM, floored z-scores, Wilson bound, decay.
- Combat publishes `Combat.Shot` for every accepted shot and first projectile hit.
- Module context `Events:Has(topic)`, for optional coupling between modules.
- Tests:
  - `Unit/Statistics` and `Unit/BehavioralDetectors`;
  - `Integration/BehavioralLegit`: 10 legitimate scenarios and the false-positive guard;
  - `ExploitSimulation/Behavioral`: 15 tests;
  - behavioural benchmarks.
  - 334 tests in total.

### Changed
- `Modules.Economy` is no longer a reserved future module. Resource-gain detection is
  Behavioral signals; configuring `Economy` now logs "Configured module is not
  registered". **Breaking** only for configs that set `Modules.Economy`, which was
  never functional.

### Verified (offline)
- No behavioural evidence for:
  - steady, lumpy, bursty, 2×-gamepass, AFK and late-joining earners;
  - a server-wide double-coins event;
  - shooters up to 80% accuracy and 55% headshots over 9,000 validated shots;
  - human clicking (CV 4–15%);
  - occasional invalid purchases.
- Reported:
  - 10× (within 60 s), 4×, colluding and from-join currency exploits;
  - 99%-accuracy aimbot, and head-lock;
  - 1 s and 0.5 s autoclickers;
  - invalid-action floods.
- Mutation checks confirm the suites aren't vacuous. Breaking any one of these fails
  tests: the median, the z clamp, the Wilson bound, the MinRatio guard, idle-bucket
  counting, the timing check.
- Not yet run in Studio.

### Added (since 0.4.0, before Phase 5)
- `RobloxPhysics.create({ GetCharacters = fn })`: choose which characters raycasts ignore.
  Needed when ACF tracks server-controlled characters (bots, NPCs).

### Verified
- NPC load test in Studio:
  - 50 real characters at 1.43 ms per sampling tick;
  - 5,100 combat validations at ~37 µs each;
  - flat memory over 60 s;
  - 0 honest bots flagged, and both cheating bots flagged.
- Morphs: four character replacements across R15/R6/scaled rigs with no false detections,
  and detection still working afterwards.

### Fixed
- Hits on head-worn accessories (hats, hair, face accessories) now count as headshots.
  This was found during the Studio verification session.

### Verified
- In Studio, live: R6 and R15 rigs, seats and vehicles, a moving platform (GroundSpeed),
  ladders, terrain water and accessory hits. See TESTING.md.

## [0.4.0] — 2026-11-17 — Phase 4: Combat Integrity

### Added
- Built-in `Combat` module (on by default; passive until weapons are defined):
  server-authoritative shot and hit validation with server-computed damage.
- Weapon kinds Hitscan, Projectile, Melee and Ability, with:
  - falloff and headshot multipliers;
  - fire rate with burst, and cooldowns;
  - magazines, reserve ammo and server-timed reloads;
  - projectile speed, gravity, lifetime and pierce.
- Checks:
  - ownership, shooter alive, ammo, reloading, cooldown, origin and fire rate;
  - hit-point mismatch, self hit, dead target, range, friendly fire and line of sight;
  - projectile unknown/duplicate shot, expiry, arrival timing and trajectory (searched
    along the real arc).
- `API/IntegrationAPI`, assigned explicitly onto the public API (so `--!strict` games see the types):
  - `DefineWeapon`, `DefineAbility` and `SetCombatProvider` (Inventory, CanDamage,
    DamageCalculator);
  - `ValidateAttack`, `FireProjectile` and `ValidateProjectileHit`;
  - `Reload`, `GetAmmo`, `SetAmmo` and `GetCombatStats`;
  - `ACF.CombatClaim`.
- `Environment.Physics:Describe(part)` plus its Roblox implementation.
- `examples/CombatWiring.server.luau`.
- Combat benchmarks in `tools/bench.sh`.
- 42 new tests (278 total): a 16-scenario legitimate-combat suite and a combat exploit suite.
- `tools/verify.sh`: a single pre-commit gate (tests, type check, build).

### Fixed (follow-up to the initial 0.4.0 commit)
- The combat methods were attached to `ACF` dynamically, so the type checker could not
  see them (`ACF:DefineWeapon` was a type error in strict-mode games). They are now
  assigned explicitly.

## [0.3.0] — 2026-11-13 — Phase 3: Movement & Physics

### Added
- Built-in `Movement` module (on by default): server-observed sampling and detectors for
  speed, teleport, flight, infinite jump, acceleration and noclip (crossed / embedded).
- Built-in `Physics` module (on by default, depends on Movement): fling, extreme velocity,
  velocity mismatch (tp-walk).
- Built-in `Telemetry` module (off by default) with `Shared/Protocol` and the client script
  `StarterPlayerScripts.ACFTelemetry`.
- Handling for respawn, seats/vehicles, death, climbing, swimming, falling, moving
  platforms, lag freezes (time credit) and ping.
- `ACF:AuthorizeTeleport(player, seconds?)` and
  `ACF:AllowMovement(player, kind, seconds, options?)`.
- `Environment.Physics` (Sample, Cast) and `Environment.Remotes`, with Roblox
  implementations in `Platform/RobloxPhysics.luau` and `RobloxEnvironment`; exposed to
  modules as `context.Platform`.
- `Intelligence/ViolationTracker`: the shared decaying violation score.
- Movement tick benchmark in `tools/bench.sh`.
- 62 new tests (236 total), including a 19-scenario legitimate-play false-positive suite.

### Changed
- RemoteSecurity's suspicion scoring now uses ViolationTracker (behaviour unchanged).
- The Rojo projects map the telemetry client script into StarterPlayerScripts.
- The test fakes provide a physics world (boxes, Roblox ray semantics) and remote provider.

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
