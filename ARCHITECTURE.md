# ACF Architecture

## 1. Placement and trust boundaries

| Code | Location | Replicates to client? |
|------|----------|-----------------------|
| Framework, detectors, evidence, configuration | `ServerScriptService.ACF` | **No** |
| Constants safe to expose (`VERSION`) | `ReplicatedStorage.ACFShared` | Yes |
| Client telemetry (Phase 3) | `StarterPlayerScripts` | Yes, untrusted |

Thresholds, enforcement policy and evidence never leave the server. The shared folder holds
only values an exploiter can read without harm.

## 2. Subsystems

```
                      ┌────────────────────────── Framework ───────────────────────────┐
 Environment ───────▶ │ Configuration ─▶ Logger ─▶ EventBus ◀─▶ Scheduler              │
 (Players, Heartbeat, │        │                     ▲    ▲         ▲                    │
  Clock, GenerateId,  │        ▼                     │    │         │                    │
  LogSink)            │  ModuleLoader ──context──▶ [Detection modules]                  │
                      │                              │ context:Report()                  │
                      │  PlayerRegistry ◀────────────┤                                   │
                      │        │                     ▼                                   │
                      │        └──────────────▶ DetectionManager ─▶ EvidenceManager      │
                      └────────────────────────────────────────────────────────────────┘
```

| Module | File | Responsibility |
|--------|------|----------------|
| Framework | `Core/Framework.luau` | Builds services, owns the framework state machine, builds module contexts |
| Configuration | `Core/Configuration.luau`, `Core/DefaultConfig.luau` | Schema validation, defaults, deep-frozen values, late module sections |
| Logger | `Core/Logger.luau` | Structured, levelled, rate-limited logging with a ring buffer |
| EventBus | `Core/EventBus.luau` | Synchronous, error-isolated pub/sub with strict topics |
| Scheduler | `Core/Scheduler.luau` | One Heartbeat connection, interval tasks, per-task CPU stats, failure disabling |
| ModuleLoader | `Core/ModuleLoader.luau` | Definition validation, dependency order, lifecycle state machine |
| PlayerRegistry | `Core/PlayerRegistry.luau` | Sessions, character generations, per-session state and cleanup |
| Cleanup | `Core/Cleanup.luau` | Reverse-order resource release, error-tolerant |
| RateLimiter | `Core/RateLimiter.luau` | Keyed token bucket with bounded keys |
| DetectionManager | `Detection/DetectionManager.luau` | Validates, rate limits, sanitises and normalises detection reports |
| EvidenceManager | `Intelligence/EvidenceManager.luau` | Bounded per-user evidence, duplicate merging, expiry |
| RobloxEnvironment | `Platform/RobloxEnvironment.luau` | The only place that reads Roblox services |
| BuiltIns | `Detection/BuiltIns.luau` | Factories for built-in modules, registered at `Initialize` |
| RemoteSecurity | `Detection/RemoteSecurity/RemoteSecurity.luau` | Protected remotes, request pipeline, suspicion tracking |
| Validators | `Detection/RemoteSecurity/Validators.luau` | Bounded, injection-safe argument schemas |
| Policies | `Detection/RemoteSecurity/Policies.luau` | Permission / ownership checks |
| Movement | `Detection/Movement/Movement.luau` | Character sampling, exemptions, allowances, reporting |
| MovementDetectors | `Detection/Movement/MovementDetectors.luau` | Pure detectors: speed, teleport, flight, air jump, acceleration, noclip |
| Physics | `Detection/Physics/Physics.luau` | Fling, extreme velocity, velocity mismatch (consumes `Movement.Sample`) |
| Telemetry | `Detection/Telemetry/Telemetry.luau` | Optional client heartbeat (weak signal) |
| Combat | `Detection/Combat/Combat.luau` | Weapon state, two-stage shot/hit validation, providers |
| CombatRules | `Detection/Combat/CombatRules.luau` | Pure: definitions, damage, projectile geometry |
| Behavioral | `Detection/Behavioral/Behavioral.luau` | Signals, actions and combat statistics per player; scheduling and reporting |
| BehavioralDetectors | `Detection/Behavioral/BehavioralDetectors.luau` | Pure: robust baselines, CUSUM signals, Wilson-bounded ratios, timing regularity |
| Statistics | `Intelligence/Statistics.luau` | Pure: EWMA, CUSUM, z-score with floors, Wilson bound, decay |
| RiskEngine | `Intelligence/RiskEngine.luau` | Core service: per-user risk from every detection, bands, history, persistence queue |
| RiskModel | `Intelligence/RiskModel.luau` | Pure: decaying saturating keys, correlation groups, noisy-OR confidence, bands, explanations |
| RobloxStore | `Platform/RobloxStore.luau` | DataStore adapter (`Environment.Store`), non-yielding, pcall-wrapped |
| IntegrationAPI | `API/IntegrationAPI.luau` | Game-facing rule definitions: combat calls, behavioural signals and actions |
| ViolationTracker | `Intelligence/ViolationTracker.luau` | Shared decaying violation score: the "never on one sample" rule |
| RobloxPhysics | `Platform/RobloxPhysics.luau` | Real character probe and ray casts |
| Protocol | `Shared/Protocol.luau` (replicated) | Remote names and intervals for the client script |
| ClientTelemetry | `Client/ClientTelemetry.client.luau` | Optional heartbeat sender (untrusted) |
| PublicAPI | `API/PublicAPI.luau` | Process-wide singleton facade |

## 3. Lifecycles

**Framework:** `Created → Initialized → Running ⇄ Stopped → Destroyed`.
`Initialize` is atomic: if configuration or a queued module is invalid, the framework stays
`Created` and the call can be retried.

**Modules:**

```
Registered ─▶ Initializing ─▶ Initialized ─▶ Starting ─▶ Running ─▶ Stopping ─▶ Stopped
     │              │                            │                      │          │
     ├▶ Disabled    └▶ Failed                    └▶ Failed              └▶ Failed  └▶ Starting (restart)
     └▶ Blocked (missing / disabled / failed dependency)
any initialized state ─▶ Destroying ─▶ Destroyed
```

Illegal transitions raise immediately because they indicate a framework bug. Every
transition is published on `ACF.ModuleStateChanged`.

**Resource scoping:** resources acquired through the context (`Events:Subscribe`,
`Scheduler:Every/After`, `Cleanup:Add`) during `Initialize` are released at `Destroy`.
Resources acquired during `Start` are released at `Stop`. A module can therefore be stopped
and restarted without leaking or duplicating subscriptions.

**Start order:** modules start first, then the PlayerRegistry. Modules therefore observe
`PlayerSessionStarted` for every player, including players already in the server.
On `Stop`, sessions end first, so modules receive `PlayerSessionEnded` while still running.

## 4. Detection data flow

1. A module calls `context:Report(target, { Kind, Severity, Confidence, Details })`.
2. The context binds the module's `Name` and `Category`, so modules cannot report under
   another identity.
3. `DetectionManager` checks, in order: the module is `Running`; the input is valid
   (Severity 0–100, Confidence 0–1, finite); the target resolves to an **active** session.
   A forged table or stale Session does not resolve.
4. A per-(session, detector) token bucket limits flooding.
5. Details are sanitised:
   - string keys only, bounded key count and string length, nesting depth ≤ 2;
   - Instances are stored as their full names, so destroyed parts aren't kept alive;
   - functions and threads are dropped.
6. A frozen `DetectionEvent` is recorded by `EvidenceManager` and published on
   `ACF.DetectionReported` together with the resulting record.

**Severity vs Confidence.** Severity is the risk weight of an observation at full certainty
(the `w` in the Phase 6 model). Confidence is how sure the detector is (`c`).
Phase 6 combines them as `R = min(100, Σ wᵢ·cᵢ·e^(−λ·tᵢ))`. Phase 1 stores both but does not
score.

## 5. Evidence model

- Keyed by **UserId**, not session. Leaving and rejoining the same server does not erase
  recent evidence. Each record keeps the SessionId it was first seen in.
- Repeated identical `(Detector, Kind)` detections within `DuplicateWindowSeconds` merge
  into one record: Count increments, and Severity/Confidence keep the maximum. A flood of
  one signal costs O(1) memory.
- Per-user cap (`MaxRecordsPerPlayer`, least-recently-seen eviction) and time-based expiry
  (`RetentionSeconds`, pruned by a scheduler task).
- Cross-server persistence is deferred to Phase 6, where it is justified by risk scoring.

## 6. Error isolation

| Fault | Effect |
|-------|--------|
| Invalid configuration / module definition | Raises at boot with every problem listed |
| Module lifecycle method throws | Module → `Failed`; dependents → `Blocked`; others unaffected |
| `Critical = true` module fails to start | `Start` raises; already-started modules are stopped |
| Event handler throws | Logged; after N consecutive failures the handler is disconnected |
| Scheduled task throws | Logged; after N consecutive failures the task is disabled |
| Log sink throws | Counted; logging continues |
| Cleanup task throws | Reported; the remaining tasks still run |

## 7. Design decisions

- **Environment injection instead of globals.** Core code never calls `game:GetService`
  for platform services (`Framework` reads only the shared `Constants` module). This makes
  every subsystem testable offline with fakes. The fakes stand in for Roblox only; ACF
  logic under test is always the real code.
- **Synchronous event bus.** Deterministic ordering, simple reasoning and testability.
  The trade-off is that handlers must not yield.
- **Central scheduler instead of per-detector Heartbeat.** One connection, measurable cost
  per task, and one place to disable a broken task.
- **`script.Parent` requires, not require-by-string.** These work in every Roblox Studio
  version. The Lune harness reproduces them via a virtual DataModel built from the same Rojo
  project file.
- **Evidence ≠ risk ≠ enforcement.** Each concern is a separate subsystem (Phase 1, 6
  and 7), as the security model requires.

## 8. Remote security (Phase 2)

Built-in modules are ordinary modules. They are registered by the Framework at
`Initialize`, use the same context and lifecycle as user modules, and can be disabled
through `Modules`. RemoteSecurity sits in front of the game's handlers:

```
client ──▶ RemoteEvent.OnServerEvent ──▶ RemoteSecurity.admit()
                                           ├─ reject ──▶ stats, decaying suspicion score ──▶ (sustained) context:Report
                                           └─ accept ──▶ pcall(Handler, player, validatedArgs...)
```

- **Fail closed.** While stopped, no request reaches a handler and RemoteFunctions return
  `RejectResponse`.
- **Per-player state** (rate limiter, cooldown, transaction ids, suspicion) lives in
  `session:GetState("RemoteSecurity.State")`, so it is bounded by the number of protected
  remotes and freed when the player leaves.
- **Suspicion.** It is a leaky integrator rather than a per-request verdict, because
  invalid requests also come from lag, version skew and game bugs. Details are in
  docs/REMOTE_SECURITY.md.

## 9. Movement and physics (Phase 3)

```
Scheduler (0.2 s) ─▶ Movement.tick ─▶ Environment.Physics:Sample(character)   [server-observed]
                                       ├─ exemptions (seated, dead, generation change)
                                       ├─ MovementDetectors.evaluate ─▶ violations ─▶ ViolationTracker ─▶ context:Report
                                       └─ publish "Movement.Sample" ─▶ Physics ─▶ violations ─▶ ViolationTracker ─▶ context:Report
```

- **Pure detectors.** `MovementDetectors` takes plain-number samples and returns weighted
  violations. All Roblox access is in `Platform/RobloxPhysics`, so every detector is tested
  against scripted legitimate and malicious traces.
- **Module dependency in practice.** `Physics` declares `Dependencies = { "Movement" }` and
  subscribes to the `Movement.Sample` topic. If Movement is disabled or fails, Physics is
  Blocked, not half-running.
- **One violation model.** Movement, Physics, RemoteSecurity and Telemetry all score through
  `ViolationTracker`. The "do not act on a single event" rule therefore lives in one
  audited place.

## 10. Combat (Phase 4)

```
client claim ─▶ ProtectEvent (types, sizes, transport rate) ─▶ game handler
                                                                  └─▶ ACF:ValidateAttack(player, weapon, claim)
                                                                        ├─ stage 1: shot legitimacy ─▶ commit ammo / cooldown
                                                                        ├─ stage 2: hit legitimacy (Physics:Describe, Physics:Cast)
                                                                        └─▶ verdict + server-computed damage ─▶ game applies it
```

- **Verdicts, not side effects.** ACF never applies damage or edits inventories. The game
  applies `result.Damage`. That keeps ACF genre-agnostic, and it means ACF bugs cannot
  corrupt game state.
- **Providers are the integration seam.** Inventory, team and damage rules are
  game-specific, so they are injectable functions with safe defaults. They fail closed.
- **Two stages.** Separating "did the shot happen" (it consumes ammo and fire-rate budget)
  from "did it hit" stops a cheater from retrying invalid hits for free.

## 11. Behavioural intelligence (Phase 5)

```
game server code ── ACF:RecordSignal / RecordAction ──┐
Combat ── "Combat.Shot" topic (validated shots) ──────┼─▶ Behavioral (per-session state)
                                                      │     ├─ every 10 s: close signal buckets,
                                                      │     │  median baseline, CUSUM
                                                      │     ├─ every 10 s: Wilson-bounded accuracy
                                                      │     │  and invalid-action ratios
                                                      │     └─ per action: timing windows
                                                      └─▶ ViolationTracker ─▶ DetectionManager
```

- **Only trusted inputs.** Signals and actions come from the game's server code. Shots
  come from Combat after validation. The client contributes nothing directly.
- **Robust to the cheater being measured.**
  - The signal baseline is the median player, not the mean.
  - Accuracy compares a player with the server *minus that player's own shots*.
- **Statistical and practical significance.** Every statistical report needs:
  - evidence over several samples (CUSUM run, Wilson bound, full timing windows);
  - an effect large enough to matter (`MinRatio`, accuracy margins and floors).
- **Optional coupling.** Behavioral subscribes to `Combat.Shot` only if the topic exists
  (`context.Events:Has`). Disabling Combat leaves Behavioral running, not Blocked.
- **Pure core.** `Statistics` and `BehavioralDetectors` have no clock or Roblox access.
  `Behavioral.luau` only owns state, timing and reporting, like Movement.

## 12. Risk (Phase 6)

```
any module ─▶ DetectionManager ─▶ EvidenceManager (records: what happened)
                     │
                     └─ ACF.DetectionReported ─▶ RiskEngine (score: how worried to be)
                                                   ├─ per (Detector, Kind): decaying, saturating score
                                                   ├─ correlation groups ─▶ R = min(100, Σ G + History)
                                                   ├─ ACF.RiskChanged on band change ─▶ (Phase 7 enforcement)
                                                   └─ session end ≥ 40 ─▶ batched Store writes
```

- **Core service, not a module.** Risk must see every module's detections, custom
  ones included, and must not be disabled by a module failure. It subscribes to the bus
  for the framework's whole life and is gated by Start/Stop.
- **Evidence and risk are separate.** EvidenceManager keeps *what happened*, with
  details. RiskEngine keeps *how much it matters now*. Enforcement (Phase 7) will be a
  third subsystem consuming `RiskChanged`, so detection, punishment and evidence stay
  separate.
- **Storage is asynchronous and fails safe.** `Environment.Store` uses callbacks; the
  Roblox adapter spawns and pcalls. Retries and batching live in RiskEngine, where the
  tests reach them. A failed load means no history, never higher risk.

## 13. Planned additions

| Phase | Additions |
|-------|-----------|
| 6 | `RiskEngine`, `ConfidenceEngine`, correlation, persistent risk via `DataStoreAdapter` |
| 7 | `EnforcementManager`, `ActionPolicy`, `Quarantine`, `BanManager`, `AuditLogger` |
