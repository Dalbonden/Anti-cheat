# ACF Architecture

## 1. Placement and trust boundaries

| Code | Location | Replicates to client? |
|------|----------|-----------------------|
| Framework, detectors, evidence, configuration | `ServerScriptService.ACF` | **No** |
| Constants safe to expose (`VERSION`) | `ReplicatedStorage.ACFShared` | Yes |
| Client telemetry (Phase 3) | `StarterPlayerScripts` | Yes, untrusted |

Thresholds, enforcement policy and evidence never leave the server. The shared folder holds
only values an exploiter can read without harm.

## 2. Subsystems (Phase 1)

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

## 8. Planned additions

| Phase | Additions |
|-------|-----------|
| 2 | `RemoteSecurity` (schemas, rate limits, permissions, idempotency), `Shared/Protocol` |
| 3 | `Movement`/`Physics` detectors, `ClientTelemetry` (treated as untrusted hints), server-authorized teleport API |
| 4 | Combat integrity + `IntegrationAPI` for game-defined combat rules |
| 5 | Behavioural statistics (EMA, CUSUM, baselines) |
| 6 | `RiskEngine`, `ConfidenceEngine`, correlation, persistent risk via `DataStoreAdapter` |
| 7 | `EnforcementManager`, `ActionPolicy`, `Quarantine`, `BanManager`, `AuditLogger` |
