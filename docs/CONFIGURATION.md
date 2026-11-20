# ACF Configuration Reference (v0.7.0)

Pass overrides to `ACF:Initialize`. Unspecified keys use the defaults below. Unknown keys,
wrong types and out-of-range values are rejected. Every problem is listed at once, with
suggestions for typos. Resolved configuration is frozen.

| Key | Default | Range / values | Notes |
|-----|---------|----------------|-------|
| `Debug` | `false` | boolean | Forces log level Debug |
| `LogLevel` | `"Info"` | Debug, Info, Warn, Error | |
| `Logging.BufferSize` | 500 | 16–10000 (int) | Entries kept for `GetRecentLogs` |
| `Logging.RateLimitBurst` | 20 | 1–1000 (int) | Identical messages allowed per window |
| `Logging.RateLimitWindowSeconds` | 10 | 0.1–3600 | |
| `Enforcement.Mode` | `"Hybrid"` | Hybrid, Manual, Off | Automatic levels 0–4; removals automatic only when corroborated (Hybrid) |
| `Enforcement.AutoKick` | `true` | boolean | Automatic kicks on corroborated evidence (Hybrid) |
| `Enforcement.AutoBan` | `false` | boolean | Automatic temporary bans; permanent bans still require approval by default |
| `Enforcement.ShadowMode` | `false` | boolean | Decide and audit, apply nothing automatic. Recommended first. |
| `Modules` | `{}` | `{ [name] = boolean }` | Enables/disables modules by name; unlisted modules use their `EnabledByDefault` |
| `ModuleSettings` | `{}` | `{ [name] = table }` | Validated against each module's `ConfigSchema` at registration; keys with no matching module fail at `Start` |
| `Detection.ReportsPerSecond` | 10 | 0.1–1000 | Sustained reports per (player, detector) |
| `Detection.ReportBurst` | 30 | 1–10000 (int) | Burst above the sustained rate |
| `Detection.MaxDetailKeys` | 32 | 0–256 (int) | Per Details table |
| `Detection.MaxDetailStringLength` | 256 | 8–4096 (int) | Longer strings are truncated |
| `Evidence.MaxRecordsPerPlayer` | 64 | 1–1024 (int) | Least-recently-seen eviction |
| `Evidence.RetentionSeconds` | 1800 | 1–86400 | Records unseen this long are pruned |
| `Evidence.DuplicateWindowSeconds` | 5 | 0–3600 | Same (Detector, Kind) within the window merges |
| `Evidence.PruneIntervalSeconds` | 30 | 1–3600 | |
| `Scheduler.MaxConsecutiveFailures` | 5 | 1–1000 (int) | Then the task is disabled |
| `EventBus.MaxHandlerFailures` | 10 | 1–1000 (int) | Then the handler is disconnected |
| `EventBus.MaxDispatchDepth` | 8 | 1–64 (int) | Nested publish limit |

**`Enforcement`** configures graduated enforcement: mode, shadow mode, band levels,
corroboration, correction, bans, cases, audit and messages. All keys are in
[ENFORCEMENT.md](ENFORCEMENT.md#configuration-enforcement).

**`Risk`** configures the central risk engine: half-life, repeat cap, correlation groups,
bands and opt-in persistence. All keys are in [RISK.md](RISK.md#configuration-risk).

**Built-in modules.** Each has its settings under `ModuleSettings.<Name>`:

| Module | Default | Settings reference |
|--------|---------|--------------------|
| `RemoteSecurity` | on | [REMOTE_SECURITY.md](REMOTE_SECURITY.md#configuration-modulesettingsremotesecurity) |
| `Movement` | on | [MOVEMENT.md](MOVEMENT.md#configuration) |
| `Physics` | on (requires Movement) | [MOVEMENT.md](MOVEMENT.md#configuration) |
| `Combat` | on (passive until weapons are defined) | [COMBAT.md](COMBAT.md#configuration-modulesettingscombat) |
| `Behavioral` | on (accuracy from Combat; signals and actions once the game records them) | [BEHAVIORAL.md](BEHAVIORAL.md#configuration-modulesettingsbehavioral) |
| `Telemetry` | off | [MOVEMENT.md](MOVEMENT.md#telemetry-optional-weak-signal) |

There is no separate `Economy` module: resource-gain detection is provided by
Behavioral signals (`ACF:DefineSignal`). Configuring `Modules.Economy` logs "Configured
module is not registered".

## Module schemas

```lua
ConfigSchema = ACF.Schema.Table({
    Threshold = ACF.Schema.Number(10, { Min = 0, Max = 100, Integer = false }),
    Enabled   = ACF.Schema.Boolean(true),
    Label     = ACF.Schema.String("x", { MaxLength = 32 }),
    Mode      = ACF.Schema.Enum({ "Strict", "Lenient" }, "Lenient"),
    Weights   = ACF.Schema.Map(ACF.Schema.Number(1, { Min = 0 }), { Default = 1 }),
})
```

Schema defaults are themselves validated when the schema is built.
