# Writing ACF Detection Modules

A module is a table with a name and four lifecycle methods. Register a **fresh table per
framework instance**: the table is the module instance.

```lua
local function new(Schema)
    local module = {
        Name = "SpeedSampler",          -- identifier, unique, max 48 chars
        Version = "1.0.0",              -- optional
        Category = "Movement",          -- Movement | Physics | Remote | Combat | Economy | Behavioral | Integrity | Custom
        Dependencies = {},              -- optional: names of modules that must run first
        Critical = false,               -- optional: if true, ACF:Start() fails when this module cannot start
        EnabledByDefault = true,        -- optional: Modules = { SpeedSampler = false } overrides
        ConfigSchema = Schema.Table({   -- optional: validated ModuleSettings.SpeedSampler
            MaxSpeed = Schema.Number(32, { Min = 0 }),
        }),
    }
    local context

    function module:Initialize(ctx)  -- one-time setup; no players yet
        context = ctx
    end

    function module:Start()          -- subscribe, schedule; released automatically at Stop
        context.Scheduler:Every("Sample", 0.5, function(now, dt)
            for _, session in context.Players:GetSessions() do
                -- observe server-side state, then maybe:
                -- context:Report(session, { Kind = "SpeedExceeded", Severity = 20, Confidence = 0.6, Details = {...} })
            end
        end)
    end

    function module:Stop() end       -- release anything not acquired through the context
    function module:Destroy() end    -- final teardown

    return module
end
```

## The context

| Member | Description |
|--------|-------------|
| `context.Name` | The module's name |
| `context.Config` | Frozen, validated `ModuleSettings.<Name>` (defaults applied) |
| `context:GetConfig(path)` | Read any global configuration value |
| `context.Logger` | Logger scoped to the module: `:Debug/:Info/:Warn/:Error(message, fields?)`. Keep messages constant; variable data goes in fields. |
| `context.Clock` | `Now()` monotonic seconds, `Wall()` Unix seconds |
| `context.Events:Subscribe(topic, fn)` | Auto-released (see scoping) |
| `context.Events:Declare(suffix)` | Registers and returns the topic `"<Name>.<suffix>"` |
| `context.Events:Publish(topic, payload)` | Only the module's own topics; `ACF.*` topics are reserved |
| `context.Events:Has(topic)` | Whether a topic exists. Use it to subscribe to an optional module's topic, e.g. `Combat.Shot`. |
| `context.Scheduler:Every(name, interval, fn, phase?)` / `:After(name, delay, fn)` | `fn(now, dt)`; auto-released |
| `context.Cleanup:Add(item)` | Function, thread, connection, Instance, or anything with `Disconnect`/`Destroy` |
| `context.Players:GetSession(target)` / `:GetSessions()` | Active sessions |
| `context:Report(target, input)` | Returns `(true, eventId)` or `(false, reason)`; never throws |
| `context:GetModule(name)` | A declared dependency's module table |

**Scoping:** whatever you acquire through the context during `Initialize` is released at
`Destroy`. Whatever you acquire during `Start` is released at `Stop`.

**Per-player state:** `session:GetState("MyModule.Key", factory)` is freed automatically
when the session ends. Prefix keys with your module name. Use `session.Cleanup:Add(...)` for
per-player connections.

## Reporting guidelines

- **Severity (0–100):** how much this observation should weigh at full certainty. Reserve
  high values for observations that legitimate play cannot produce.
- **Confidence (0–1):** how certain you are. A single unusual sample should rarely exceed
  ~0.5. Raise confidence with repeated or corroborated evidence, not with a larger Severity.
- **Kind:** stable machine-readable identifier (≤ 64 chars). Identical `Kind`s merge within
  the duplicate window. Use distinct Kinds for distinct phenomena.
- **Details:** the explanation, i.e. what was measured, the limit, and the time window.
  Sanitised and size-limited; Instances become their full names.
- Detecting is not punishing. Modules never kick or ban; enforcement is a separate
  subsystem (Phase 7).
- Use server-observed state. Client-provided data is a hint at best.

## Worked example

`examples/LeaderstatRateDetector.luau` is a complete module with configuration, scheduling,
per-session state and explained reports. Its tests are in
`tests/Specs/Integration/ExampleDetector.spec.luau`.
