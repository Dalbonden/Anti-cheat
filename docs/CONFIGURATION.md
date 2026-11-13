# ACF Configuration Reference (v0.1.0)

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
| `Enforcement.Mode` | `"Hybrid"` | Hybrid, Manual, Off | **Inert until Phase 7** |
| `Enforcement.AutoKick` | `true` | boolean | **Inert until Phase 7** |
| `Enforcement.AutoBan` | `false` | boolean | **Inert until Phase 7**; permanent bans will require human approval by default |
| `Enforcement.ShadowMode` | `false` | boolean | **Inert until Phase 7** |
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

Built-in module names `RemoteSecurity`, `Movement`, `Physics`, `Combat`, `Economy` and
`Behavioral` are reserved. Enabling one before its phase ships logs a warning naming the
phase.

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
