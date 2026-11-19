# Behavioural Intelligence (v0.5.0)

`Behavioral` is a built-in module, enabled by default. It finds cheating that no single
request reveals, only a pattern over time:

- income far above everyone else's;
- aim that is too accurate for too long;
- clicks spaced like a machine's;
- a client that keeps sending actions its own UI can't produce.

It only sees data the server already trusts:

- amounts the game's server code grants;
- actions the game's server code records;
- shots that Combat has already validated.

Nothing is read from the client.

| Detector | Data source | Reported Kind | Default severity |
|----------|-------------|---------------|------------------|
| Signal hard limit | `RecordSignal` | `SignalRateLimit` | 30 |
| Signal anomaly | `RecordSignal` | `SignalAnomaly` | 20 |
| Accuracy | Combat (hitscan and projectile) | `AccuracyAnomaly` | 25 |
| Headshots | Combat (hitscan and projectile) | `HeadshotAnomaly` | 25 |
| Timing | `RecordAction` | `RegularTiming` | 15 |
| Invalid actions | `RecordAction(…, false)` | `RepeatedInvalidActions` | 10 |

**Behavioural evidence is statistical.** Confidence is capped at 0.8
(`Violation.MaxConfidence`), and every report carries the numbers that produced it. Treat
it as a reason to look closer, not as proof. Phase 7 enforcement will not act on
behavioural evidence alone.

## Quick start

```lua
local ACF = require(game.ServerScriptService.ACF)
ACF:Initialize({})
ACF:DefineSignal("Coins")                          -- statistical only
ACF:DefineSignal("Gems", { MaxPerSecond = 2 })     -- plus a hard limit
ACF:Start()

-- Wherever the SERVER grants the resource:
local function giveCoins(player, amount)
    data[player].Coins += amount
    ACF:RecordSignal(player, "Coins", amount)
end

-- Wherever the server handles a player-initiated action:
clickRemote.OnServerEvent:Connect(function(player)
    ACF:RecordAction(player, "Click")
end)
buyRemote.OnServerEvent:Connect(function(player, itemId)
    local item = Shop[itemId]
    -- This game's client only shows items the player can afford, so an unknown item or
    -- an unaffordable purchase never comes from the real client (see "Invalid actions").
    local valid = item ~= nil and data[player].Coins >= item.Price
    ACF:RecordAction(player, "Buy", valid)
    if valid then
        purchase(player, item)
    end
end)
```

Combat accuracy needs no code. If you use `ACF:ValidateAttack` / `FireProjectile`, the
statistics come from Combat automatically.

## Signals: resource and progression rates

### Model

1. **Buckets.** Each player's amounts are summed over buckets of `BucketSeconds` (10 s)
   and turned into a rate per second.
   - A player's first, partial bucket is discarded.
   - After that, *every* bucket counts, empty ones included. A player paid in lumps (100
     coins every 20 s) and one paid steadily (5 per second) then have the same mean.
2. **Personal baseline.** Each player keeps an EWMA mean and variance of their own rate
   (`SelfAlpha` 0.2, roughly the last 10 buckets).
3. **Population baseline.** This is robust:
   - the **median** of eligible players' means;
   - scale = the largest of the median personal standard deviation, 1.4826 × the median
     absolute deviation of the means, `MinStdDev`, and `MinRelativeStdDev` × median.

   A player is eligible after `MinPlayerBuckets` buckets and with activity in the last
   `ActiveWithinBuckets` buckets, so AFK players don't drag the baseline down. At least
   `MinContributors` (4) eligible players are needed.

   **One cheater cannot move a median.** The model only assumes most players in the
   server are honest. Two exploiters among seven are both caught (tested).
4. **Change detection.** Each bucket of a recently active player is standardised against
   the baseline (z, clamped to ±`ZClamp` = 3) and fed into an upper CUSUM:
   `S ← max(0, S + z − k)`, with k = 0.5. It alarms when S > h, with h = 6.
   - Empty or normal buckets pull S back down.
   - With the clamp, **an alarm needs at least three strongly anomalous buckets**. No
     single payout, however large, can raise one.
5. **Practical significance.** An alarm reports only when the player's own mean is at
   least `MinRatio` (3) × the baseline.
   - That guard keeps 2× coin gamepass owners clean; the tests show they are otherwise
     flagged.
   - If your multipliers can exceed 3×, record the amount *before* multipliers, or raise
     `MinRatio`.

`SignalAnomaly` details include:

| Field | Meaning |
|-------|---------|
| `Signal` | Which signal alarmed |
| `RatePerSecond` | Rate in the bucket that tipped it |
| `PlayerMean` | The player's own mean rate |
| `BaselineMean`, `BaselineScale` | The baseline it was compared with |
| `BaselineSource` | `Population` or `Defined` |
| `BaselinePlayers` | How many players formed the baseline |
| `Ratio` | `PlayerMean / BaselineMean` |
| `Cusum` | The CUSUM statistic when it alarmed |
| `Buckets` | How many buckets the run lasted |

### Small servers

With fewer than 4 active players there is no population baseline. **Statistical signal
detection is then off** (tested). Two ways to cover small servers:

```lua
-- 1. A known expected rate (per second, idle time included) from your own analytics:
ACF:DefineSignal("Coins", { Baseline = { Mean = 5, StdDev = 2 } })
-- 2. A hard limit on what is physically possible:
ACF:DefineSignal("Coins", { MaxPerSecond = 100 })
```

### Hard limit (`MaxPerSecond`)

`SignalRateLimit` is reported when a bucket's rate exceeds `MaxPerSecond` × 1.1. Its weight
is 1–2 by excess, so it needs at least two buckets. Set it to what is *impossible* over 10
seconds, not to what is merely unusual. `Statistical = false` turns off the CUSUM for a
signal that should only have a hard limit.

### Signal options

| Option | Default | Meaning |
|--------|---------|---------|
| `MaxPerSecond` | none | Hard limit |
| `Baseline` | none | `{ Mean, StdDev }` per second. Replaces the population baseline. |
| `MinStdDev` | 0 | Floor on the baseline scale, in signal units per second |
| `Statistical` | true | Run the CUSUM |

## Combat accuracy

Combat publishes every accepted shot on the `Combat.Shot` topic. Hits are counted only
when they land on a character and pass all of Combat's checks. Each projectile counts its
first character hit, not pierce hits. Melee and abilities are excluded.

**Model.** Per player and per weapon, ACF keeps decayed counts (half-life 600 s) of shots,
hits and headshots, plus the same totals for the server. Every `EvaluateIntervalSeconds`
(10 s) it computes:

- the **Wilson lower bound** (z = 3.09, one-sided 99.9%) of the player's hit ratio;
- the server's ratio for that weapon **with the player's own shots removed**.

| Check | Minimum sample | Reported when the lower bound exceeds |
|-------|----------------|---------------------------------------|
| Accuracy | 40 shots | max(server ratio + 0.35, **0.90**) |
| Headshots per hit | 20 hits | max(server ratio + 0.40, **0.75**) |

When the server has fewer than 200 shots (or 100 hits) on that weapon, only an absolute
floor applies: **0.95** for accuracy and **0.90** for headshots.

The lower bound is the skill guard. A short perfect streak has a wide interval and is not
flagged. Each violation weighs 1, and the report threshold is 3, so the bound must stay
above the threshold for three evaluations.

What the tests established:

| Player | Result |
|--------|--------|
| Shooters at 30–80% accuracy, up to 55% headshots, 9,000 validated shots | Clean |
| A lone player at 85% accuracy and 50% headshots | Clean |
| 99% accuracy | Reported |
| 95% headshots at normal accuracy | Reported (headshots only) |

Details include `Weapon`, `Shots`/`Hits`/`Headshots`, `Ratio`, `LowerBound`, `Threshold`,
`PopulationRatio` and `Basis` (`Population` or `Absolute`).

**Tune per game.** In a game where 90% hitscan accuracy is normal (huge hitboxes, slow
targets), raise `AccuracyFloor`.

## Actions: timing and invalid actions

### Timing (`RegularTiming`)

Humans are irregular. Even deliberately rhythmic tapping varies by several percent from
one tap to the next.

- **Model.** The intervals between one player's actions of one kind are judged over
  non-overlapping windows of 30. A window is reported when its coefficient of variation
  (std ÷ mean) is below `MaxCV` (0.02) and its mean interval is between 0.1 s and 10 s.
- A gap over 30 s starts a new run.
- Each window weighs 1.5, so two windows are needed.

**Only record actions the player initiates.** Anything the server triggers on a timer
(auto-collect, regeneration, a tick reward) is perfectly regular by construction and
*will* be reported.

**Known limitation.** The server sees each action when it arrives, on a 60 Hz frame and
after network jitter. That adds spread the clicker never had:

| Autoclicker | Result (tested) |
|-------------|-----------------|
| 1 s, any frame phase | Reported |
| 0.5 s, mid-frame, 3 ms jitter | Reported |
| 0.5 s exactly on a frame boundary | Missed: jitter flips each click between two frames, adding ±17 ms |
| 0.25 s with 15 ms jitter | Missed |

Clickers that add random delays defeat this detector entirely. It catches simple macros;
nothing more is claimed.

### Invalid actions (`RepeatedInvalidActions`)

`RecordAction(player, action, false)` marks an action as invalid.

- **Model.** Decayed counts (half-life 60 s). The report needs at least 20 decayed invalid
  actions, and a Wilson lower bound (z = 2.33) of the invalid ratio above 0.8, for three
  evaluations.
- A frustrated player clicking "Buy" while broke is not reported (tested). A script firing
  a purchase remote three times a second for a minute is.

**Only mark an action invalid when your own client could never send it.** For example:

- the client hides the button when the player can't afford the item;
- the target is out of range in the client's own UI.

If your UI allows the action and the server refuses it, that's normal play: record it as
valid.

## API

| Method | Returns | Notes |
|--------|---------|-------|
| `ACF:DefineSignal(name, options?)` | — | After `Initialize`. Names are 1–64 characters and unique; at most 64 signals. Unknown option keys error. |
| `ACF:RecordSignal(player, name, amount)` | boolean | `amount` must be finite, ≥ 0 and ≤ 1e12. Otherwise it returns `false` and changes nothing. An undefined signal errors. |
| `ACF:RecordAction(player, action, valid?)` | boolean | At most 32 distinct actions per player; further names are dropped (`ActionsDropped`). |
| `ACF:GetBehaviorProfile(player)` | table? | `Signals`, `Weapons`, `Actions`: per-player statistics |
| `ACF:GetBehaviorStats()` | table | Baselines per signal, `CombatConnected`, `ShotsObserved`, violation counts |

All state is per session: leaving the server clears it. Population baselines are
per server.

## Configuration (`ModuleSettings.Behavioral`)

| Section | Key | Default |
|---------|-----|---------|
| `Signals` | BucketSeconds | 10 |
| | SelfAlpha | 0.2 |
| | MinPlayerBuckets | 3 |
| | ActiveWithinBuckets | 6 |
| | MinContributors | 4 |
| | MinRelativeStdDev | 0.1 |
| | ZClamp | 3 |
| | CusumK | 0.5 |
| | CusumH | 6 |
| | MinRatio | 3 |
| | HardLimitTolerance | 0.1 |
| | MaxSignals | 64 |
| `Accuracy` | HalfLifeSeconds | 600 |
| | EvaluateIntervalSeconds | 10 |
| | ConfidenceZ | 3.09 |
| | MinShots | 40 |
| | AccuracyMargin | 0.35 |
| | AccuracyFloor | 0.9 |
| | AccuracyFloorWithoutBaseline | 0.95 |
| | MinPopulationShots | 200 |
| | MinHits | 20 |
| | HeadshotMargin | 0.4 |
| | HeadshotFloor | 0.75 |
| | HeadshotFloorWithoutBaseline | 0.9 |
| | MinPopulationHits | 100 |
| `Actions` | WindowSize | 30 |
| | MaxCV | 0.02 |
| | MinMeanIntervalSeconds | 0.1 |
| | MaxMeanIntervalSeconds | 10 |
| | MaxGapSeconds | 30 |
| | InvalidHalfLifeSeconds | 60 |
| | MinInvalid | 20 |
| | MaxInvalidRatio | 0.8 |
| | InvalidConfidenceZ | 2.33 |
| | MaxActionsPerPlayer | 32 |
| `Detectors` | SignalRateLimit, SignalAnomaly, Accuracy, Headshots, Timing, InvalidActions | all true |
| `Severity` | SignalRateLimit | 30 |
| | SignalAnomaly | 20 |
| | Accuracy | 25 |
| | Headshots | 25 |
| | Timing | 15 |
| | InvalidActions | 10 |
| `Violation` | HalfLifeSeconds | 120 |
| | ReportThreshold | 3 |
| | ReportIntervalSeconds | 60 |
| | ConfidenceScale | 6 |
| | MaxConfidence | 0.8 |

## Performance

Measured with `tools/bench.sh` under Lune:

| Operation | Cost |
|-----------|------|
| `RecordSignal` | ~1.2 µs |
| `RecordAction` | ~1.9 µs |
| Bucket close and evaluation, 50 players × 4 signals, every 10 s | ~0.38 ms |

## Assumptions and limits

- Most players in a server are honest; the median baseline fails if they are not.
- Population baselines are per server and reset when it shuts down. Cross-server baselines
  need persistence (Phase 6).
- Statistical detectors catch *sustained* abuse. A single large exploit followed by
  normal play is a job for the hard limit, or for your own server-side validation.
- Accuracy depends on the game's hit model. Defaults are conservative; tune the floors per
  game.
