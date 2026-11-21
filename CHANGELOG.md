# Changelog

All notable changes are documented here. ACF uses [Semantic Versioning](https://semver.org/).
Before 1.0.0, minor versions may contain breaking changes; each one is listed.

## [1.0.0-rc.2] — 2026-11-21 — developer experience and canary tooling

### Added
- `docs/MIGRATION.md`: upgrading from each version to the next, with behaviour changes and
  required actions. This was missing from the brief's developer-experience deliverables.
- `docs/INTEGRATION.md`: step-by-step wiring of a whole game, with a checklist.
- `examples/ConfigProfiles.luau`: Shooter, Simulator, Platformer, Roleplay and ObserveOnly
  configurations, booted by the new `Unit/ConfigProfiles` test so they can't go stale.
- `examples/StaffCommands.server.luau` + `StaffCommandsClient.client.luau`: in-game staff
  commands for cases, removals, overrides and lookups. They use a TextChatCommand, so other
  players never see them, and every action is audited.
- `examples/AuditToDataStore.server.luau`: the audit log batched to DataStore, for the
  canary review and appeals.

### Fixed
- `AuditToDataStore` crashed on load where DataStores are unavailable; it now warns and
  continues.
- Example scripts now wait for `ACF:Initialize`, since Script order is not guaranteed.

### Verified
- The staff commands, live in Studio with TextChatService (TESTING.md, "Staff tooling").
- 426/426 tests.

## [1.0.0] — 2026-11-20 — Phase 8: Testing and Production Release

Released on the canary channel as `1.0.0-rc.1`. Stable follows the canary criteria in
RELEASING.md.

### Added
- `tests/Specs/Simulation.luau`: a deterministic population simulator.
  - **Honest players:** walking, sprinting, jumps, lag spikes, jitter, respawns, server
    teleports, shooting, earning patterns, human clicking, shop remote.
  - **Nine cheat types:** speed, teleport, fly, noclip, aimbot, rapid fire, coin dupe,
    autoclicker, remote spam.
- `tests/lune/evaluate.luau` / `tools/evaluate.sh`. They measure:
  - detection accuracy and time to detect;
  - honest false positives;
  - live enforcement outcomes;
  - CPU per tick at 10/50/100 players;
  - a 2-hour churn soak with a faulty module, counting ACF's per-user structures;
  - logging cost.

  The results are in `docs/EVALUATION.md`.
- `Integration/Population` (CI population run) and `Integration/Latency` (honest players
  at 0.02–0.9 s ping).
- Release channels: `Constants.CHANNEL`, `ACF.Channel`, `GetStatus().Channel`;
  `tools/release.sh canary|stable`; `RELEASING.md`; `examples/CanaryBootstrap.server.luau`.
- Enforcement:
  - review cases for players restricted longer than
    `Cases.ReviewAfterRestrictedSeconds` (10 min);
  - departed players forgotten after `ForgetAfterSeconds` (1 h);
  - `GetStatus().Enforcement.Users` / `Records`.

### Fixed (found by Phase 8 testing)
- **Teleport and speed bypass (found in the live Studio run).** The lag time credit was
  uncapped, so standing still for a minute licensed a ~1,200-stud jump. It is now
  capped at `Movement.MaxTimeCreditSeconds` (3 s).
- **False positive (found by the simulation).** A lag spike in mid-air looked like
  hovering (`Flight`). Frozen airborne samples that still report velocity are now
  treated as a replication stall, with credit capped at 3 s per airborne period.
- **Memory growth (found by the soak).**
  - A forgotten player's decaying risk re-created enforcement state.
  - Review cases opened as risk *decayed* through Investigation, and for departed
    players; they now open only on a rising band for a present player.
  - Open cases pinned departed users.
  - Departed risk users waited for every kind to decay below 0.05; they are now
    forgotten below total risk 1.

### Changed (calibration from the evaluation)
These are behaviour changes; see docs/EVALUATION.md for the before and after.
- `Risk.RepeatCap` 2 → 3: sustained severe evidence can now reach correction and review.
- Movement `Severity.Speed` 20 → 25.
- Behavioral `Severity.SignalAnomaly` 20 → 30 and `Accuracy`/`Headshots` 25 → 30;
  `Violation.ConfidenceScale` 6 → 3. Statistical evidence still never removes anyone
  automatically.

### Verified
- 420/420 tests under Lune and in Roblox Studio's VM (Studio 0.748).
- Evaluation, 10 seeds, 50 honest player-hours:
  - honest players: 0 with evidence, 0 restricted, 0 would-be removals;
  - every cheat type caught in every run.
  - CPU: ~1 ms per tick at 50 players (Lune).
  - The soak's per-user structures are bounded.
- Live Studio, Play mode, with the real `RobloxEnvironment`:
  - **Movement correction.** A client-side 150-stud teleport was pulled back within
    0.25–0.28 s, three times out of three. The correction is visible on the client.
  - **Latency.** Honest walking and jumping for 45 s at a measured 278 ms and 790 ms
    NetworkPing (Network Simulator) produced no evidence. A teleport at 790 ms was still
    detected.
  - **DataStore failure.** In an unpublished place every call fails. Risk continues
    without history; enforcement retries 5×, then audits `PersistenceFailed`. Nothing
    crashes.
  - **Kicks.** `Player:Kick` fires `PlayerRemoving` after 1.1 s and is audited with the
    staff name.
  - **Ban API.** `Players:BanAsync` returns success instantly *and does nothing* in an
    unpublished place (PlaceId 0), so real bans can only be verified in a published game.

### Not verified (open for the canary period)
- Several real clients in one server (multi-client network load). Studio's
  single-client Play was the limit here.
- `Players:BanAsync` and DataStore persistence in a published experience.

## [0.7.0] — 2026-11-20 — Phase 7: Hybrid Enforcement

**Behaviour change:** ACF now acts on risk. With the defaults (Hybrid, AutoKick on,
AutoBan off):

- it restricts tagged operations at risk ≥ 40;
- it corrects movement at ≥ 60;
- it kicks at ≥ 80 only on corroborated, non-statistical evidence.

Use `Enforcement.ShadowMode = true` first. Documented in docs/ENFORCEMENT.md.

### Added
- `Enforcement/EnforcementManager`, a core service separate from detection and risk:
  - **Levels 0–7:** logging, monitoring, rejection, correction, temporary restriction,
    kick, temporary ban, permanent ban.
  - **Restrictions** by risk-group tags:
    - `ProtectEvent/ProtectFunction` spec `Restrict = "<tag>" | true`, rejection reason
      `restricted`, not scored as suspicion;
    - Combat refuses shots from Combat/Aim-restricted players (`Reason = "Restricted"`).
  - **Movement correction** at level 3, rate-limited and distance-capped, back to the
    last grounded clean position. The correction is authorised, so it isn't scored.
  - **Corroboration rule** for automatic removal. Statistical evidence alone never
    removes anyone automatically.
  - **Escalation:** kick → temporary ban (24 h, doubling, capped) → permanent-ban
    proposal. Permanent bans need approval by default. A removed player is not removed
    again until new evidence arrives.
  - **Cases:** a staff approval workflow (`GetCases`, `ApproveCase`, `RejectCase`,
    `OnEnforcementCase`), review cases at the Investigation band, and expiry.
  - **Staff actions:** `Kick`, `Ban` (offline too), `Unban`, and overrides (`Exempt` or a
    level, with expiry). Every one requires `By`.
  - **Ban records** persisted per user: active ban, expiry, history and appeal
    references (`ACF-XXXXXXXX`).
    - Enforced on join.
    - Roblox `Players:BanAsync` as well, by default.
    - Immediate effect even when storage fails.
    - Retries, and a flush at shutdown.
  - **Audit log:** every decision and staff action. Bounded, repeats summarised,
    published on `ACF.EnforcementAudit`.
  - **Shadow mode:** everything decided and audited, nothing automatic applied.
- `EnforcementPolicy` and `BanRecords` (pure), `AuditLog`.
- Platform:
  - `RobloxEnforcer` (Kick, BanAsync, UnbanAsync);
  - `Environment.Enforcer`;
  - `PhysicsService.Correct`.
- Module context: `context.Enforcement` (`IsRestricted`, `ShouldCorrect`, `NoteCorrected`).
- Topics `ACF.EnforcementAudit` and `ACF.EnforcementCase`.
- Tests: `Unit/EnforcementPolicy` (with BanRecords) and `Integration/Enforcement` (21).
  Fakes for the enforcer, physics correction and per-scope store counters. 405 tests.

### Fixed during the phase
- The detection that triggered a kick also cleared the "wait for new evidence" guard, so
  a kicked player would have been kicked again on rejoin. Only evidence after the
  removal now counts.
- Ban records for offline players were written only on the next tick; they are now
  written as soon as the record has loaded.
- Bans no longer wait for the stored record to load before removing the player.

### Verified (offline)
- Seven mutation checks are each caught: statistical corroboration, unapproved permanent
  bans, shadow mode, the new-evidence guard, the join ban check, exempt overrides and
  the temporary-restriction window.
- The false-positive suites (MovementLegit, CombatLegit, BehavioralLegit) are unchanged
  and clean.
- No measurable benchmark regression on remote, combat or movement paths.
- Not yet run in Studio. `BanAsync`, `Kick` and DataStore records need a live check.

## [0.6.0] — 2026-11-20 — Phase 6: Risk Scoring and Evidence

### Added
- `Intelligence/RiskEngine`, a core service: one risk score (0–100) per player from every
  accepted detection, built-in or custom. Documented in docs/RISK.md.
  - Confidence-weighted, exponentially decaying evidence per (Detector, Kind). The
    first detection adds severity × confidence, matching
    `R = Σ wᵢ·cᵢ·e^(−λtᵢ)`.
  - Duplicate suppression: repeats within `RepeatSuppressSeconds` are not added, and
    later repeats saturate at `RepeatCap` × severity × confidence.
  - Correlation groups (`Risk.Groups`): related kinds count once plus 25% of the rest.
  - Bands Normal / Increased / Restrict / Investigation / EnforcementReview
    (20/40/60/80), with a new `ACF.RiskChanged` topic on every band change.
  - Noisy-OR confidence across independent groups.
  - Session risk per UserId: rejoining does not reset it.
  - Opt-in persistent risk (`Risk.Persistence`):
    - saved only for sessions ending at ≥ 40;
    - seeds later sessions as weighted, decayed and capped "History", which on its own
      reaches at most Increased;
    - batched writes with retries, flushed on Stop and at server shutdown.
  - Evidence history, plain-text explanations, and the `ResetRisk` staff override.
- `Intelligence/RiskModel`: the pure mathematics.
- `Platform/RobloxStore`: a DataStore adapter.
- `Environment.Store` and `Environment.OnShutdown`; RobloxEnvironment wires
  `BindToClose`.
- API:
  - `ACF:GetRisk`, `ACF:GetRiskHistory`, `ACF:ResetRisk`, `ACF:OnRiskChanged`;
  - `GetStatus().Risk`.
- Tests: `Unit/RiskModel`, `Integration/Risk` and `Integration/RiskPersistence` (37 new);
  fake Store with latency and failure injection; risk benchmarks. 372 tests in total.

### Verified (offline)
- The R formula holds to four decimal places.
- A burst of 20 duplicates counts once.
- 20 minutes of one repeated cheat stays in Restrict.
- Correlated detections give 37.5, where independent ones give 60.
- Persistence:
  - load failure, corrupt records and late loads are handled safely;
  - failed writes are retried, then given up;
  - writes are batched;
  - shutdown flushes everything.
- Eight mutation checks are each caught: correlation, saturation, suppression,
  confidence weighting, the stale-load guard, the history cap, the save threshold and
  save retries.
- Not yet run in Studio. The real DataStore needs API access enabled.

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
