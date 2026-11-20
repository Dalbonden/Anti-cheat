# Risk Scoring and Evidence (v1.0.0)

Every module reports detections; the **RiskEngine** turns them into one number per player:

- **Risk:** 0–100.
- **Band:** a response band (below).
- **Confidence:** how independently corroborated the evidence is.
- **Explanation:** a plain-text breakdown of what drove the score.

It is a core service, not a module, so it sees detections from built-in and custom
modules alike. It **never punishes anyone**. Phase 7 enforcement acts on its bands.

```lua
local report = ACF:GetRisk(player)
print(report.Risk, report.Band, report.Confidence)
print(report.Explanation)
--[[
Risk 62.7 (Investigation)
  Movement 36.8: SpeedExceeded x2 (Movement, sev 20, conf 1, 30) + TeleportDetected x2 (Movement, sev 30, conf 0.6, 27)
  Aim 25.9: AccuracyAnomaly x2 (Behavioral, sev 25, conf 0.74, 25.9)
]]

ACF:OnRiskChanged(function(change)
    -- change.UserId, change.Band, change.PreviousBand, change.Risk, change.Explanation
end)
```

## Bands

| Risk | Band | Intended response (Phase 7) |
|------|------|-----------------------------|
| 0–19 | `Normal` | Normal monitoring |
| 20–39 | `Increased` | Increased monitoring |
| 40–59 | `Restrict` | Restrict suspicious operations |
| 60–79 | `Investigation` | Investigation |
| 80–100 | `EnforcementReview` | Enforcement review |

These are starting values, not tuned production thresholds. Change them with
`Risk.Bands`; each lower bound must be greater than the previous one, or `Initialize`
fails. `ACF.RiskChanged` fires whenever a player's band changes, both up and down.

## Model

### Per kind

Each (Detector, Kind) pair, for example `Movement.TeleportDetected`, has its own score:

```
decay:  S ← S · 0.5^(Δt / H)                        λ = ln 2 / H, H = Risk.HalfLifeSeconds (600)
add:    S ← S + w·c · max(0, 1 − S / (w·c·RepeatCap))
```

`w` is the detection's severity and `c` its confidence.

- **One detection adds exactly w·c.** With different kinds this is the brief's formula,
  `R = Σ wᵢ·cᵢ·e^(−λtᵢ)`; the tests check it to four decimal places.
- **Confidence weighting.** A detection at confidence 0.5 counts half as much as one at
  1.0.
- **Duplicate suppression, two layers:**
  - Repeats of the same kind within `RepeatSuppressSeconds` (5) are not added at all;
    they are counted as `Suppressed`.
  - Later repeats have diminishing returns and approach w·c·`RepeatCap` (3×).
    - A low-severity kind can never climb far on its own: severity 15 tops out near 40.
    - A *sustained*, severe kind can. Twenty minutes of Flight (severity 30, confidence
      0.9) approaches 81, which is EnforcementReview. This was calibrated in Phase 8: with
      2×, flying, teleporting and speed cheaters were never corrected or reviewed
      (docs/EVALUATION.md).
- **Evidence expiration.** Everything decays. Kinds below 0.05 are pruned, and players
  who left are forgotten once their risk falls below 1.

### Correlation: avoiding double counting

One cheat often trips several related detectors. A teleport, for example, trips speed,
teleport and velocity-mismatch checks. Kinds are therefore grouped, and within a group
the strongest kind counts fully while the rest count at `SecondaryWeight` (0.25):

```
G = max(Sₖ) + SecondaryWeight · (Σ Sₖ − max(Sₖ))
R = min(100, Σ G + History)
```

Two related detections at 30 give 37.5, not 60; two independent ones give 60 (tested).

Default groups (`Risk.Groups`, matched by `Detector.Kind`, then Detector, then Category):

| Group | Members |
|-------|---------|
| `Movement` | Movement and Physics |
| `Aim` | `AccuracyAnomaly`, `HeadshotAnomaly` |
| `Economy` | `SignalAnomaly`, `SignalRateLimit` |
| `Automation` | `RegularTiming`, `RepeatedInvalidActions` |
| Anything else | Its own category: `Combat`, `Remote`, `Integrity`, `Custom`, … |

Your entries merge over the defaults:

```lua
ACF:Initialize({ Risk = { Groups = { ["MyDetector.Wallhack"] = "Aim" } } })
```

### Confidence

`Confidence` = 1 − Π(1 − c_g), a noisy-OR over groups of each group's strongest
confidence. Groups are treated as independent evidence, which is exactly why correlated
kinds are grouped first.

## Session and persistent risk

**Session risk** is kept per UserId for the life of the server. Leaving and rejoining does
not reset it (tested); it decays like any evidence.

**Persistent risk** is off by default; turn it on with
`Risk = { Persistence = { Enabled = true } }`. It applies only where it is justified:

- **Saving.** Only a session that ends at risk ≥ `MinRiskToSave` (40) is saved. Clean
  sessions cause no writes.
- **Seeding.** On the next join, the saved risk seeds the session as a `History`
  contribution:

  ```
  History = min(Cap, saved × Weight × 0.5^(hours since / HalfLifeHours))
                  35         0.5              24 h
  ```

  History alone can never leave `Increased`. A week later it adds nothing (tested).
- **Batching.** Writes are queued and flushed every `FlushIntervalSeconds` (30), at most
  `MaxWritesPerFlush` (10) at a time. They are also flushed on `ACF:Stop()` and at
  server shutdown (`BindToClose`, waiting up to 25 s for writes in flight).
- **Failure handling:**
  - A failed write is retried up to `MaxAttempts` (3) and then logged as an Error.
  - A failed or corrupt load means *no history*; it never raises risk.
  - A load that finishes after the player has left is discarded.
- **Record.** Stored at key `Risk_<UserId>` in DataStore `ACF_Risk_v1`:

  ```lua
  {
      Version = 1, Risk = 47.5, WallTime = 1763600000,
      Sessions = { { WallTime, Risk, Peak, Band, Top = { { Group, Score, Kind } } } }, -- last 5
      ResetReason = "..."?,
  }
  ```

  It holds no personal data beyond the UserId in the key.

In Studio, persistence needs *Game Settings → Security → Enable Studio Access to API
Services*. Without it every load fails, which is harmless and logged.

## History and explanations

`ACF:GetRiskHistory(player)` returns up to `MaxHistory` (50) entries, oldest first:

| `Type` | Meaning |
|--------|---------|
| `Detection` | A detection that changed risk, with `Detector`, `Kind`, `Group`, `Contribution` and the resulting `Risk`/`Band` |
| `Band` | A band change, `Note = "Restrict -> Investigation"` |
| `History` | Risk loaded from an earlier session |
| `Reset` | A staff reset, with the reason |

Full detection details stay in the evidence store (`ACF:GetEvidence`). Risk links to
them by Detector and Kind.

`ACF:ResetRisk(player, { Reason = "...", Persistent = true })` is the staff override. It
clears session risk and, with `Persistent`, writes a Risk-0 record that keeps the
session list for audit. It is logged, and recorded in the player's history.

## API

| Method | Returns |
|--------|---------|
| `ACF:GetRisk(player)` | `{ UserId, Risk, Band, Confidence, Persistent, Peak, Groups = { { Group, Score, Confidence, Kinds } }, Explanation }` |
| `ACF:GetRiskHistory(player)` | History entries, as above |
| `ACF:ResetRisk(player, options?)` | — |
| `ACF:OnRiskChanged(handler)` | Subscription; payload as in `ACF.Topics.RiskChanged` |
| `ACF:GetStatus().Risk` | Tracked and elevated users, detections, suppressed, band changes, persistence counters |

`player` may be a Player, Session or UserId; departed players are fine.

## Configuration (`Risk`)

| Key | Default |
|-----|---------|
| Enabled | true |
| HalfLifeSeconds | 600 |
| RepeatCap | 3 |
| RepeatSuppressSeconds | 5 |
| SecondaryWeight | 0.25 |
| RecomputeIntervalSeconds | 5 |
| MaxKeysPerUser | 64 |
| MaxHistory | 50 |
| Bands | Increased 20, Restrict 40, Investigation 60, EnforcementReview 80 |
| Groups | See above (merged) |
| Persistence.Enabled | false |
| Persistence.DataStoreName | `ACF_Risk_v1` |
| Persistence.MinRiskToSave | 40 |
| Persistence.Weight | 0.5 |
| Persistence.HalfLifeHours | 24 |
| Persistence.Cap | 35 |
| Persistence.FlushIntervalSeconds | 30 |
| Persistence.MaxWritesPerFlush | 10 |
| Persistence.MaxAttempts | 3 |
| Persistence.MaxSessions | 5 |

## Performance

Measured with `tools/bench.sh` under Lune:

| Operation | Cost |
|-----------|------|
| Detection → evidence → risk update (whole pipeline) | ~8 µs |
| Periodic recompute, 50 users × 6 kinds, every 5 s | ~0.26 ms |

Memory per user is bounded by `MaxKeysPerUser` (weakest kind evicted) and `MaxHistory`.

## What the numbers mean

Risk aggregates evidence; it is not a probability of cheating. Severities are set per
detector, confidences per detection, and both are judgement calls. Before acting
automatically, watch real servers, using `ShadowMode` when Phase 7 lands, and tune the
bands.
