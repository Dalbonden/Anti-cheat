# Integrating ACF into a game

This guide wires a complete game, from install to enforcement. Each step names the
reference document for the details. Most snippets come from the `examples/` folder, which
is type-checked against the real API on every commit.

## 1. Install

**From a release:** open `ACF-<version>.rbxm` (RELEASING.md) and drag its three folders'
contents into the matching services:

| Folder in the model | Goes into |
|---------------------|-----------|
| `ServerScriptService/ACF` | ServerScriptService |
| `ReplicatedStorage/ACFShared` | ReplicatedStorage |
| `StarterPlayerScripts/ACFTelemetry` | StarterPlayer → StarterPlayerScripts (only if you enable Telemetry) |

**With Rojo:** map `src/` as `default.project.json` does (README.md, Installation).

Nothing server-side replicates. `ACFShared` holds only harmless constants.

## 2. Bootstrap

One Script in ServerScriptService:

```lua
local ACF = require(game:GetService("ServerScriptService"):WaitForChild("ACF"))

ACF:Initialize({
    Enforcement = { ShadowMode = true },   -- decide and audit, apply nothing (step 9)
})
-- define weapons, signals and custom modules here (steps 4-6)
ACF:Start()
```

`examples/ConfigProfiles.luau` has ready-made configurations for shooters, simulators,
platformers and roleplay games. Every key is listed in CONFIGURATION.md. Invalid
configuration fails `Initialize` and lists every problem.

Other scripts that use ACF should wait until it is initialised. Roblox does not
guarantee Script order.

```lua
while ACF:GetStatus().State == "Created" do task.wait() end
```

## 3. Protect every remote

Every RemoteEvent and RemoteFunction the client can fire goes through
`ProtectEvent` / `ProtectFunction`. That gives it argument validation, rate limits,
permissions, idempotency and suspicion scoring. See REMOTE_SECURITY.md.

```lua
local V = ACF.Validators
ACF:ProtectEvent(Remotes.BuyItem, {
    Arguments = { V.string({ MaxLength = 32 }), V.integer({ Min = 1, Max = 99 }) },
    RateLimit = { Burst = 5, PerSecond = 1 },
    Restrict = "Economy",            -- refused while the player is restricted for Economy
    Handler = function(player, itemId, quantity) ... end,
})

for _, remote in ACF:FindUnprotectedRemotes(game.ReplicatedStorage) do
    warn("Unprotected remote: " .. remote:GetFullName())
end
```

**Which `Restrict` tag?** Use the risk group the operation would help a cheater with:

| Tag | For |
|-----|-----|
| `Economy` | Trades, purchases, code redemption |
| `Combat` / `Aim` | Damage |
| `Movement` | Travel and teleport requests |
| `true` | Any restriction at all |

Operations without a tag are never restricted.

## 4. Tell ACF about server-driven movement

Movement is judged from what the server observes. When *your* code moves a character,
say so first, or it looks like a cheat. See MOVEMENT.md.

```lua
ACF:AuthorizeTeleport(player)                         -- before PivotTo, spawns, portals
character:PivotTo(destination)

ACF:AllowMovement(player, "Speed", 2, { Multiplier = 3 })   -- dash
ACF:AllowMovement(player, "Impulse", 1)                     -- knockback, launch pad
ACF:AllowMovement(player, "Flight", 10)                     -- jetpack, glider
```

WalkSpeed and JumpPower changes made on the server are picked up automatically.

## 5. Let the server decide hits and damage

The client sends a *claim*. ACF checks the shot and the hit with server raycasts, and
computes the damage. Your code applies it. See COMBAT.md and
`examples/CombatWiring.server.luau`.

```lua
ACF:DefineWeapon("Rifle", { Kind = "Hitscan", Damage = 25, HeadshotMultiplier = 2,
    FireRate = 10, MaxRange = 400, Ammo = { Magazine = 30, Reserve = 120, ReloadSeconds = 2 } })

ACF:ProtectEvent(Remotes.Fire, {
    Arguments = { V.string({ MaxLength = 32 }), ACF.CombatClaim },
    RateLimit = { Burst = 20, PerSecond = 20 },
    Handler = function(player, weaponId, claim)
        local result = ACF:ValidateAttack(player, weaponId, claim)
        if result.Allowed and result.Target and result.Target.Humanoid and result.Damage > 0 then
            result.Target.Humanoid:TakeDamage(result.Damage)
        end
    end,
})
```

Accuracy and headshot statistics come from these validated shots automatically.

## 6. Report your economy and player actions

ACF can't see your currency. Tell it where the server grants things, and which actions
players start. See BEHAVIORAL.md.

```lua
ACF:DefineSignal("Coins")                         -- before Start
ACF:RecordSignal(player, "Coins", amount)         -- wherever the server grants coins
ACF:RecordAction(player, "Click")                 -- player-initiated actions only, never timers
ACF:RecordAction(player, "Buy", valid)            -- valid = false only for what your UI can't send

if ACF:IsRestricted(player, "Economy", "Shop.Buy") then return end   -- in your own code
```

Record amounts **before** gamepass multipliers above 3×.

## 7. Custom detectors (optional)

Anything game-specific (lap times, puzzle solves, trading patterns) can be a module.
Write it with `ACF:RegisterModule`, report through `context:Report`, and it flows into
risk and enforcement like the built-ins. See MODULES.md and
`examples/LeaderstatRateDetector.luau`.

## 8. Staff tooling

Enforcement needs people for cases, appeals and false positives. The examples are ready
to adapt:

| Example | What it gives you |
|---------|-------------------|
| `StaffCommands.server.luau` + `StaffCommandsClient.client.luau` | `/acf cases`, `case`, `approve`, `reject`, `risk`, `kick`, `ban`, `unban`, `exempt`, `unexempt` as TextChatService commands that other players never see; new cases announced to staff; every action audited with the staff member's name |
| `AuditToDataStore.server.luau` | The enforcement audit log batched to DataStore, for appeals and the canary review across servers |
| `CanaryBootstrap.server.luau` | Enforcement switched on for a share of servers by JobId |

Set your staff UserIds or group rank at the top of `StaffCommands.server.luau`. Staff
are always decided on the server.

## 9. Roll out

1. **Shadow mode.** Publish with `ShadowMode = true`. Read the audit log: `ShadowAction`
   (would remove), `Rejected` (would refuse) and `Corrected` entries. Investigate any
   that hit a player you trust.
2. **Tune.** Adjust thresholds per game. The most common ones are listed in
   TROUBLESHOOTING.md.
3. **Enforce gradually.** Use `CanaryBootstrap` (10% → 50% → 100% of servers).
4. **Monitor.** Watch `ACF:GetStatus()` for failed modules, disabled tasks and pending
   writes, and keep reviewing cases.

## Checklist

| Done | Item |
|------|------|
| ☐ | Every client-firable remote protected (`FindUnprotectedRemotes` returns nothing) |
| ☐ | Sensitive remotes tagged with `Restrict` |
| ☐ | Every server teleport preceded by `AuthorizeTeleport` |
| ☐ | Dashes, knockback and jetpacks granted with `AllowMovement` |
| ☐ | Weapons defined; damage applied only from `ValidateAttack` results |
| ☐ | Currency grants reported with `RecordSignal` |
| ☐ | Staff UserIds or group set in the staff commands |
| ☐ | Audit log persisted (or `OnEnforcementAudit` wired to your own storage) |
| ☐ | Ran in shadow mode on real servers before enforcing |
