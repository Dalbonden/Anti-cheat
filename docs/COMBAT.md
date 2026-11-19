# Combat Integrity (v0.5.0)

`Combat` is a built-in module, enabled by default. It is passive until you define weapons.

The server decides every hit and every point of damage. The client sends a **claim**:
"I fired weapon X from here, and hit this part at this point". ACF checks the claim
against server-observed state and returns a verdict, with damage it computed itself. The
client can never supply damage, fire rate, range or ammo.

## Quick start

```lua
ACF:Initialize({})
ACF:DefineWeapon("Rifle", {
    Kind = "Hitscan", Damage = 25, HeadshotMultiplier = 2, FireRate = 10, MaxRange = 400,
    Falloff = { Start = 150, End = 400, MinMultiplier = 0.6 },
    Ammo = { Magazine = 30, Reserve = 120, ReloadSeconds = 2 },
})
ACF:ProtectEvent(remotes.Fire, {
    Arguments = { ACF.Validators.string({ MaxLength = 32 }), ACF.CombatClaim },
    Handler = function(player, weaponId, claim)
        local result = ACF:ValidateAttack(player, weaponId, claim)
        if result.Allowed and result.Target and result.Target.Humanoid then
            result.Target.Humanoid:TakeDamage(result.Damage)
        end
    end,
})
ACF:Start()
```

A complete version is in `examples/CombatWiring.server.luau`.

## Definitions (`ACF:DefineWeapon` / `ACF:DefineAbility`)

| Field | Default | Notes |
|-------|---------|-------|
| `Kind` | required | `"Hitscan"`, `"Projectile"`, `"Melee"` or `"Ability"` (`DefineAbility` sets it) |
| `Damage` | 0 | Base damage per hit |
| `HeadshotMultiplier` | 1 | Applied when the hit part is the `Head`, or a head-worn accessory (a hat or hair Handle welded to the head, or with a Hat/Hair/Face attachment) |
| `Falloff` | none | `{ Start, End, MinMultiplier }`: linear from 1 at Start to MinMultiplier at End |
| `FireRate` | required for Hitscan/Projectile | Shots per second |
| `Burst` | 1 | Shots allowed back-to-back above the rate (burst weapons) |
| `Cooldown` | 0 | Seconds between uses (abilities) |
| `MaxRange` | required | Studs |
| `Ammo` | infinite | `{ Magazine, Reserve = math.huge, ReloadSeconds = 0 }` |
| `ProjectileSpeed` | required for Projectile | Studs/s |
| `ProjectileGravity` | 0 | Downward acceleration, studs/s² |
| `ProjectileLifetime` | 5 | Seconds |
| `Pierce` | 0 | Extra targets one projectile may hit |
| `RequireLineOfSight` | true | |
| `RequireTarget` | true for Melee | Abilities may target a point (`HitPosition`) instead |

Invalid definitions raise at definition time with the offending field. Unknown fields are
rejected.

## Calls

| Method | Use |
|--------|-----|
| `ACF:ValidateAttack(player, weaponId, claim)` | Hitscan, Melee and Ability. Claim: `{ Origin?, Target?, HitPosition? }` |
| `ACF:FireProjectile(player, weaponId, claim)` | When a projectile is fired. Claim: `{ Origin, Direction, ShotId }` |
| `ACF:ValidateProjectileHit(player, shotId, claim)` | When it lands. Claim: `{ Target?, HitPosition? }` |
| `ACF:Reload(player, weaponId)` | Server-timed reload; returns `(ok, reason?)` |
| `ACF:GetAmmo(player, weaponId)` | `magazine, reserve, reloading` (server truth) |
| `ACF:SetAmmo(player, weaponId, magazine, reserve?)` | Pickups, loadouts, game-managed ammo |
| `ACF:SetCombatProvider(name, fn)` | See providers below |
| `ACF.CombatClaim` | Remote argument validator for claims |

**Result:**

```
{ Allowed, Reason?, ShotAccepted, Damage, Headshot, Target?, Distance? }
```

- `Target` is `{ X, Y, Z, Model, Humanoid, Alive, Player, IsHead }`.
- `ShotAccepted = true, Allowed = false` means the shot was legitimate (ammo consumed) but
  the hit was refused.
- Apply `Damage` yourself; ACF never changes game state.

## Providers

| Provider | Signature | Default |
|----------|-----------|---------|
| `Inventory` | `(player, weaponId, definition) -> boolean` | A Tool named `weaponId` in the character or Backpack. Abilities are always allowed. |
| `CanDamage` | `(attacker, targetInfo) -> boolean` | No damage to a teammate on the same non-neutral Team |
| `DamageCalculator` | `(info) -> number` | None. `info` = `{ Attacker, Weapon, Target, Distance, Headshot, BaseDamage }` |

A provider that errors **fails closed**: it is treated as a denial and logged. A
`DamageCalculator` that errors falls back to the base damage.

## Checks

**Stage 1: was the shot legitimate?** A passing shot consumes ammo and starts the cooldown.

| Reason | Check | Weight |
|--------|-------|--------|
| `UnknownWeapon` | Weapon id not defined (creates no state) | 3 |
| `InvalidClaim` | Malformed claim (wrong types, NaN, missing Origin/Direction/ShotId) | 2 |
| `ShooterDead` | No character or Health ≤ 0 | 1 |
| `NotOwned` | Inventory provider denies | 3 |
| `Reloading` / `NoAmmo` | Server ammo state | 1 / 1 |
| `Cooldown` | Within Cooldown (−0.1 s tolerance) | 1 |
| `OriginMismatch` | Claimed origin > 8 studs (+ ping × speed) from the shooter's server position | 2 |
| `FireRate` | Token bucket: Burst capacity, refill FireRate × 1.15 | 1.5 |

**Stage 2: is the hit plausible?** The hit is refused, but the shot still counts.

| Reason | Check | Weight |
|--------|-------|--------|
| `HitMismatch` | Claimed hit point > 6 studs (+ ping × 32) from the part's server position | 1 |
| `SelfHit` | Target is the shooter's own character | 0.5 |
| `TargetDead` | Target already dead (kill races are normal) | **0** |
| `OutOfRange` | Beyond MaxRange × 1.1 + 5 (+ ping × 32) | 2 |
| `FriendlyFire` | CanDamage denies | 0.5 |
| `NoLineOfSight` | World geometry between origin and hit (characters ignored) | 1.5 |
| `UnknownShot` | Projectile hit for a shot never fired, or already consumed | 2 |
| `DuplicateShot` | ShotId reused while still in flight | 2 |
| `ProjectileExpired` | Impact after ProjectileLifetime | 1 |
| `ProjectileTiming` | Impact earlier than the projectile could arrive along its path (+ ping, + 0.15 s) | 2 |
| `OffTrajectory` | The fired path never passes within 6 studs + 3% of distance of the impact | 2 |

**Projectile paths are searched, not assumed straight.** ACF finds the earliest moment the
real trajectory (direction, speed, gravity) passes within tolerance of the impact. Lobbed
and angled shots are therefore judged correctly, and the timing check uses that moment.

**Reporting.** Rejections feed the shared `ViolationTracker` (half-life 20 s, threshold 6),
so one desynced shot never reports. Reported kinds are `Combat<Reason>`, e.g.
`CombatFireRate` or `CombatNoLineOfSight`. Weights, severities and tolerances live under
`ModuleSettings.Combat`.

**Accuracy and headshot ratios** are judged by the Behavioral module, statistically and
against the server's own players ([BEHAVIORAL.md](BEHAVIORAL.md#combat-accuracy)). Combat
feeds it through the `Combat.Shot` topic:

- one `{ Event = "Shot", Hit, Headshot }` per accepted shot;
- one `{ Event = "Hit" }` for a projectile's first character hit.

Reaction time is not judged: the server cannot observe it reliably.

## Latency

| Allowance | Default |
|-----------|---------|
| Ping compensation | Up to 0.5 s, widening the range, hit-point and origin tolerances |
| Origin tolerance | Includes ping × the shooter's allowed speed |
| Fire rate | 15% refill margin, so jittery delivery isn't penalised |

All three are configurable. Both the legitimate-combat and cheat suites run with these
defaults.

## Configuration (`ModuleSettings.Combat`)

| Key | Default |
|-----|---------|
| OriginToleranceStuds | 8 |
| RangeToleranceFraction / RangeToleranceStuds | 0.1 / 5 |
| HitToleranceStuds | 6 |
| MaxTargetSpeed | 32 |
| MaxPingCompensationSeconds | 0.5 |
| LineOfSightEndToleranceStuds | 2 |
| CooldownToleranceSeconds | 0.1 |
| FireRateTolerance | 1.15 |
| ProjectileTimingToleranceSeconds | 0.15 |
| ProjectileTrajectoryToleranceStuds / Fraction | 6 / 0.03 |
| MaxPendingProjectiles | 32 per player |
| Weights.<Reason>, Severity.<Reason> | See tables above |
| Violation | HalfLifeSeconds 20, ReportThreshold 6, ReportIntervalSeconds 10, ConfidenceScale 10 |

## Performance (Lune, indicative)

| Case | Cost |
|------|------|
| Validated hitscan hit (with line-of-sight cast) | ~16 µs |
| Projectile fire + arcing hit validation | ~36 µs |

`Physics:Describe` (the real target lookup in `RobloxPhysics`) still needs a Studio run.
