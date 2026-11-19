# ACF Public API (v0.5.0)

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

## Remote security

See [REMOTE_SECURITY.md](REMOTE_SECURITY.md) for spec fields and validators.

| Method | Description |
|--------|-------------|
| `ACF:ProtectEvent(remote, spec)` | Protects a RemoteEvent or UnreliableRemoteEvent. Requires `Initialize`. Returns `{ Name, Unprotect() }`. |
| `ACF:ProtectFunction(remote, spec)` | Protects a RemoteFunction. Rejected calls return `spec.RejectResponse`. |
| `ACF:FindUnprotectedRemotes(root)` | Remote instances under `root` without protection |
| `ACF:GetRemoteStats()` | `{ [name] = { Kind, Accepted, Rejected, HandlerErrors, Reports } }` |

## Combat (integration API)

See [COMBAT.md](COMBAT.md). Definitions and providers require `Initialize`; validation calls require ACF running.

| Method | Description |
|--------|-------------|
| `ACF:DefineWeapon(id, definition)` / `ACF:DefineAbility(id, definition)` | Declare a weapon or ability and its rules |
| `ACF:SetCombatProvider(name, fn)` | `"Inventory"`, `"CanDamage"`, `"DamageCalculator"`; nil restores the default |
| `ACF:ValidateAttack(player, weaponId, claim)` | Hitscan / Melee / Ability verdict with server-computed damage |
| `ACF:FireProjectile(player, weaponId, claim)` / `ACF:ValidateProjectileHit(player, shotId, claim)` | Projectile fire and impact |
| `ACF:Reload(player, weaponId)`, `ACF:GetAmmo(...)`, `ACF:SetAmmo(...)` | Server-side ammo |
| `ACF:GetCombatStats()` | `{ Weapons = { [id] = { Shots, Hits, Rejected } }, Rejected }` |
| `ACF.CombatClaim` | Validator for claim arguments in `ProtectEvent` |

## Behaviour (integration API)

See [BEHAVIORAL.md](BEHAVIORAL.md). `DefineSignal` requires `Initialize`; recording requires ACF running.

| Method | Description |
|--------|-------------|
| `ACF:DefineSignal(name, options?)` | Declare a per-player rate (currency, XP). `options`: `MaxPerSecond`, `Baseline = { Mean, StdDev }`, `MinStdDev`, `Statistical` |
| `ACF:RecordSignal(player, name, amount)` | Add a server-granted amount. Returns false for invalid amounts; errors for an undefined signal. |
| `ACF:RecordAction(player, action, valid?)` | Record a player-initiated action for timing and invalid-action checks |
| `ACF:GetBehaviorProfile(player)` | Per-player `{ Signals, Weapons, Actions }` statistics, or nil |
| `ACF:GetBehaviorStats()` | Baselines per signal, `CombatConnected`, `ShotsObserved`, violation counts |

## Movement allowances

See [MOVEMENT.md](MOVEMENT.md). Both require ACF to be running with the Movement module active.

| Method | Description |
|--------|-------------|
| `ACF:AuthorizeTeleport(player, seconds?)` | Call right before the server moves a character. Suppresses teleport/speed/noclip checks for `seconds` (default 1). |
| `ACF:AllowMovement(player, kind, seconds, options?)` | `kind` = `"Teleport"`, `"Speed"` (`options.Multiplier`, default 2), `"Flight"`, `"Noclip"`, `"Impulse"` or `"All"`. Returns false if the player has no session. |

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
| `ACF.Version` | `"0.5.0"` |
| `ACF.Validators` | Argument validators for protected remotes |
| `ACF.Permissions`, `ACF.Ownership` | Reusable policy checks for protected remotes |
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
