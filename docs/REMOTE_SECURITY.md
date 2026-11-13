# Remote Security (v0.2.0)

`RemoteSecurity` is a built-in module, enabled by default. It validates every request to the
RemoteEvents and RemoteFunctions you protect, before your handler runs. It also reports
**sustained** abuse as evidence. A single bad request is never reported.

## Protecting a remote

```lua
local ACF = require(game:GetService("ServerScriptService").ACF)
local V = ACF.Validators
local remotes = game:GetService("ReplicatedStorage").Remotes

ACF:Initialize({})

ACF:ProtectEvent(remotes.BuyItem, {
    Arguments = { V.string({ MaxLength = 32 }), V.integer({ Min = 1, Max = 99 }) },
    RateLimit = { Burst = 5, PerSecond = 1 },
    Cooldown = 0.25,
    Handler = function(player, itemId, quantity)
        -- itemId is a string of at most 32 valid UTF-8 bytes; quantity an integer in 1..99
    end,
})

ACF:ProtectFunction(remotes.GetPrice, {
    Arguments = { V.string({ MaxLength = 32 }) },
    RejectResponse = nil,           -- returned for rejected calls and handler errors
    Handler = function(player, itemId)
        return Prices[itemId]
    end,
})

ACF:Start()
```

Use `Handler` instead of connecting `OnServerEvent` or setting `OnServerInvoke` yourself.
Protections may be created before or after `Start`. Each call returns
`{ Name, Unprotect() }`.

## Spec fields

| Field | Required | Description |
|-------|----------|-------------|
| `Handler` | yes | `function(player, ...validatedArgs)`. Errors are logged, never blamed on the player. |
| `Arguments` | yes | Array of validators, one per argument (`{}` for none). Extra arguments are rejected. Missing ones arrive as `nil`, so use `V.optional`. |
| `Name` | no | Stats and evidence name (default: the remote's Name). Must be unique. |
| `RateLimit` | no | `{ Burst, PerSecond }` token bucket per player (default: `ModuleSettings.RemoteSecurity.DefaultRateLimit`, 10 / 5 per second). |
| `Cooldown` | no | Minimum seconds between *accepted* requests per player. |
| `Permission` | no | `function(player, ...args) -> (allowed, reason?)`. Errors deny (fail closed). |
| `Ownership` | no | Same shape. Use for "does this player own the object referenced?" |
| `Idempotency` | no | `{ Argument = index, WindowSeconds = 60, MaxEntries = 64 }`. Rejects a repeated transaction id (string/number argument) within the window. Memory per player is capped. |
| `RequireCharacter` | no | Reject while the player has no character. |
| `SuspicionWeights` | no | Per-remote overrides of the suspicion weights below (e.g. `{ InvalidArguments = 0 }`). |
| `RejectResponse` | no | RemoteFunctions only. |

Unknown fields raise an error, so typos are caught.

## Validators (`ACF.Validators`)

| Validator | Default limits / notes |
|-----------|------------------------|
| `number({ Min, Max, Integer })`, `integer({ Min, Max })` | NaN and ±infinity always rejected |
| `string({ MinLength, MaxLength, Pattern, AllowInvalidUtf8 })` | MaxLength **256**, valid UTF-8 required |
| `boolean()`, `literal(value)`, `enum({ ... })` | |
| `optional(v)`, `union(v1, v2, ...)`, `custom(name, fn)` | `custom` errors count as rejection |
| `array(v, { MinLength, MaxLength })` | MaxLength **64**; sequential keys only, no holes |
| `struct({ Field = v }, { AllowExtra })` | Unknown keys rejected unless AllowExtra |
| `map(keyV, valueV, { MaxEntries })` | MaxEntries **32** |
| `instance(className?, { DescendantOf })` | `DescendantOf` = Instance or `function(value) -> Instance?` |
| `vector3({ MaxMagnitude })`, `cframe()` | Non-finite components rejected |

Tables are walked with an entry budget. An oversized table is rejected after at most
`limit + 1` entries, so a 100,000-element table costs about the same as a small one.
Error messages contain only schema paths and value *types*, never attacker-supplied
text, so logs cannot be injected or bloated.

## Policies (`ACF.Permissions`, `ACF.Ownership`)

```lua
Permission = ACF.Permissions.groupRank(GROUP_ID, 200)                  -- fails closed on lookup errors
Permission = ACF.Permissions.userIds({ 1234, 5678 })
Permission = ACF.Permissions.all(checkA, checkB)   -- also .any
Ownership  = ACF.Ownership.descendantOfCharacter(1)                    -- argument 1 inside player's character
Ownership  = ACF.Ownership.descendantOf(1, function(player) return Plots[player] end)
Ownership  = ACF.Ownership.attribute(1, "OwnerUserId")                -- or an ancestor's attribute
```

## Request pipeline

| # | Check | Rejection reason | Suspicion weight (default) |
|---|-------|------------------|----------------------------|
| 1 | Player has an active session | `no_session` | — |
| 2 | Rate limit | `rate_limited` | 1 |
| 3 | Argument count and validators | `invalid_arguments` | 2 |
| 4 | Character present (if required) | `no_character` | — |
| 5 | Cooldown | `cooldown` | 0.5 |
| 6 | Permission | `permission_denied` | 3 |
| 7 | Ownership | `ownership_denied` | 3 |
| 8 | Transaction id not seen | `duplicate_transaction` | 0.5 |
| 9 | Handler runs (pcall) | — (logged) | — |

**Fail closed:** while ACF is stopped, events are ignored and functions return
`RejectResponse`. Clients are never left yielding.

## Suspicion model

**Input:** rejections per (player, remote, reason).

**Model:** a leaky integrator with half-life `H`:
`score ← score · 0.5^(Δt / H) + w_reason`.

**Output:** when `score ≥ ReportThreshold`, and the last report for that pair is at least
`ReportIntervalSeconds` old, ACF reports a detection with:

| Field | Value |
|-------|-------|
| Detector | `RemoteSecurity` |
| Category | `Remote` |
| Kind | `RemoteInvalidArguments`, `RemoteRateLimitExceeded`, `RemotePermissionDenied`, `RemoteOwnershipViolation`, `RemoteCooldownViolation` or `RemoteDuplicateTransaction` |
| Severity | the configured severity for that reason |
| Confidence | `min(0.95, 1 − e^(−score / ConfidenceScale))` |
| Details | Remote, Reason, Score, Threshold, HalfLifeSeconds, LastProblem |

**Behaviour with defaults** (H = 30 s, threshold 6):

| Traffic | Result |
|---------|--------|
| One malformed request (score 2) | Never reported |
| Occasional mistakes spaced over minutes | Decay away; never reported |
| Laggy client delivering a short burst (a few rate-limited requests) | Not reported |
| Three malformed requests in quick succession | Reported |
| Two ownership violations | Reported |
| Sustained flooding | Reported once per interval; evidence merges duplicates |

These behaviours are covered by `tests/Specs/ExploitSimulation/Remotes.spec.luau`.

## Configuration (`ModuleSettings.RemoteSecurity`)

| Key | Default |
|-----|---------|
| `DefaultRateLimit.Burst` / `.PerSecond` | 10 / 5 |
| `Suspicion.HalfLifeSeconds` | 30 |
| `Suspicion.ReportThreshold` | 6 |
| `Suspicion.ReportIntervalSeconds` | 10 |
| `Suspicion.ConfidenceScale` | 10 |
| `Suspicion.Weights.{RateLimited, InvalidArguments, Cooldown, PermissionDenied, OwnershipDenied, Duplicate}` | 1, 2, 0.5, 3, 3, 0.5 |
| `Suspicion.Severity.{same keys}` | 10, 15, 5, 20, 25, 5 |

Disable the module with `Modules = { RemoteSecurity = false }`. `ProtectEvent` then raises.

## Auditing

```lua
for _, remote in ACF:FindUnprotectedRemotes(game:GetService("ReplicatedStorage")) do
    warn("Unprotected remote:", remote:GetFullName())
end
print(ACF:GetRemoteStats())   -- { [name] = { Kind, Accepted, Rejected = { [reason] = n }, HandlerErrors, Reports } }
```

## Performance (Lune, indicative)

`tools/bench.sh`:

| Case | Cost |
|------|------|
| Accepted request, 2 scalar arguments | ~3 µs |
| Accepted request, array of 32 structs | ~60 µs |
| Invalid argument rejection | ~4 µs |
| Rate-limited flood rejection | ~2 µs |
| 100,000-element table rejection | ~11 µs |

Re-measure on a Roblox server in Phase 8.
