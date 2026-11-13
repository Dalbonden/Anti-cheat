# Troubleshooting

**"ACF configuration is invalid"** — Read the list: every bad key is reported with its full
path and, for typos, a suggestion. Fix and call `ACF:Initialize` again (the failed call
changed nothing).

**"ModuleSettings.X: no registered module with a ConfigSchema has this name"** — A
`ModuleSettings` key does not match the `Name` of any registered module that has a
`ConfigSchema`. Check spelling, or check that `RegisterModule` ran before `Start`.

**"Configured module is not available in this ACF version"** — You enabled a built-in
(e.g. `Movement`) whose phase has not shipped. The warning names the phase.

**A module shows `Failed` in `ACF:GetStatus().Modules`** — The `Error` field contains the
lifecycle method and the error message. Modules that depend on it show `Blocked`.

**My event handler stopped firing** — Handlers that throw repeatedly are disconnected. Look
for "Event handler disconnected after repeated failures" in `ACF:GetRecentLogs()`.

**A scheduled task stopped running** — Same mechanism: "Scheduled task disabled after
repeated failures". `ACF:GetStatus().Scheduler[<Module>.<task>]` shows its failure counts.

**`context:Report` returns `false, "rate_limited"`** — The detector is reporting faster than
`Detection.ReportsPerSecond` / `ReportBurst` for that player. Report state changes, not
every sample.

**`context:Report` returns `false, "no_session"`** — The target is not an active player, the
Session object belongs to an ended session, or the value is not a real Player.

**My remote handler never runs** — Check `ACF:GetRemoteStats()[name].Rejected`.
`invalid_arguments` usually means the validators don't match what your client sends.
Remember that trailing optional arguments need `V.optional`. If nothing is counted at
all, ACF may not be running (protected remotes fail closed).

**"ACF: call ACF:Initialize before protecting remotes"** — Call `ProtectEvent` /
`ProtectFunction` after `ACF:Initialize` (before or after `Start`).

**A RemoteFunction returns nil for valid requests** — The handler probably errored. ACF
returns `RejectResponse` and logs "Remote handler errored".

**"ACF can only run on the server"** — ACF was required from a LocalScript. It belongs in
ServerScriptService.

**Log lines end with "(+N suppressed)"** — Rate limiting collapsed N identical messages.
Increase `Logging.RateLimitBurst` while debugging if needed.
