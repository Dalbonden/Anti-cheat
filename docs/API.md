# ACF Public API (v0.1.0)

```lua
local ACF = require(game:GetService("ServerScriptService").ACF)
```

Server only. Calling from a client errors ("ACF can only run on the server").

## Lifecycle

| Method | Description |
|--------|-------------|
| `ACF:Initialize(config?)` | Validates configuration and builds core services. Raises with every problem listed; can be retried after fixing. Call once. |
| `ACF:RegisterModule(definition)` | Registers a detection module. Allowed before `Initialize` (queued) or before the first `Start`. Validates the definition and its `ModuleSettings` section. |
| `ACF:Start()` | Resolves dependencies, initialises and starts modules, then begins tracking players. Returns a status table. Raises if a `Critical` module fails. |
| `ACF:Stop()` | Ends sessions, stops modules, unbinds the scheduler. `Start` may be called again. |

## Queries

| Method | Returns |
|--------|---------|
| `ACF:GetStatus()` | `{ State, Version, Modules = { [name] = { State, Error?, Critical } }, ModuleOrder, Players, Evidence, Detections, EventBus, Scheduler, Logging }` |
| `ACF:GetSession(player)` | The active `Session` or `nil`. Accepts a Player, UserId or Session. |
| `ACF:GetEvidence(player, filter?)` | Frozen `EvidenceRecord`s, oldest first. Accepts a Player, Session or UserId; works after the player has left until expiry. `filter = { Detector?, Category?, Since? }` |
| `ACF:GetEvidenceSummary(player)` | `{ Records, TotalDetections, Merged, Evicted, Expired, ByCategory }` |
| `ACF:GetConfig(path)` | Resolved (frozen) configuration value, e.g. `"Evidence.RetentionSeconds"` |
| `ACF:GetRecentLogs(count?)` | Most recent log entries, oldest first |

## Events

| Method | Description |
|--------|-------------|
| `ACF:OnDetection(handler)` | `handler({ Event, Record, IsNewRecord })` for every accepted detection. Returns a subscription with `:Disconnect()`. |
| `ACF:Subscribe(topic, handler)` | Subscribe to any core topic in `ACF.Topics` |

Handlers run synchronously and must not yield; use `task.spawn` for slow work. A handler
that throws 10 times in a row (configurable) is disconnected.

`ACF.Topics`: `FrameworkStateChanged`, `ModuleStateChanged`, `PlayerSessionStarted`,
`PlayerSessionEnded`, `CharacterSpawned`, `CharacterRemoving`, `DetectionReported`.
See `src/Server/Core/Topics.luau` for payloads.

## Values

| Field | Description |
|-------|-------------|
| `ACF.Version` | `"0.1.0"` |
| `ACF.Schema` | Schema constructors for module `ConfigSchema`s |
| `ACF.RejectReasons` | `module_not_running`, `no_session`, `invalid_input`, `rate_limited` |
| `ACF.Framework` | The class, for isolated instances: `ACF.Framework.new(environment)` |

## Types

**DetectionEvent**
`{ Id, Detector, Category, Kind, UserId, SessionId, Severity, Confidence, Time, WallTime, Details }`

**EvidenceRecord**
`{ Id, UserId, SessionId, Detector, Category, Kind, Severity, Confidence, Count, FirstSeen, LastSeen, FirstWallTime, LastWallTime, FirstEventId, Details }`

**Session**
`{ SessionId, UserId, Name, Player, JoinedAt, JoinedWallTime, Character, CharacterGeneration, Active, Cleanup }`
plus `:GetState(key, factory?)` and `:ClearState(key)`.

`Time`, `FirstSeen`, `LastSeen` and `JoinedAt` are monotonic seconds (`os.clock`).
The `*WallTime` fields are Unix seconds.
