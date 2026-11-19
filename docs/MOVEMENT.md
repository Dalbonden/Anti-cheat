# Movement, Physics and Telemetry (v0.3.0)

Three built-in modules:

| Module | Default | Category | What it checks |
|--------|---------|----------|----------------|
| `Movement` | on | Movement | Speed, teleport, flight, infinite jump, acceleration, noclip |
| `Physics` | on (needs Movement) | Physics | Fling, extreme velocity, velocity mismatch (tp-walk) |
| `Telemetry` | **off** | Integrity | Client heartbeat presence and sequence |

All detection is **server-observed**. Every 0.2 s ACF samples each character's root part
and humanoid on the server:

- position and velocity;
- server-side WalkSpeed, JumpPower and JumpHeight;
- distance to the ground (water counts as ground);
- humanoid state, seat, health and ping.

The client is never asked where it is.

**Never on a single sample.** Each detector produces *weighted violations* that feed a
decaying per-player score (`ViolationTracker`). ACF reports only when the score reaches
the threshold. One odd position update cannot reach it.

## Detectors

| Detector | Signal | Weight | Reported Kind |
|----------|--------|--------|---------------|
| Speed | Horizontal distance over a 0.5–2 s window > allowed speed × window (+ ping, + slack) | 1–4, by excess | `SpeedExceeded` |
| Teleport | Displacement between distinct positions larger than the allowed speed covers in the elapsed time (+ ping, + 10 studs), or a rise above jump apex + platform allowance | 4 | `TeleportDetected` |
| Flight | Airborne longer than a full jump arc (+1 s) while falling slower than 4 studs/s | 1 per sample | `Flight` |
| InfiniteJump | Rising ≥ 3 studs mid-air after descending, more than `MaxAirJumps` times | 2.5 | `AirJump` |
| Acceleration | Change in reported horizontal velocity > 600 studs/s² | 1 | `AbnormalAcceleration` |
| Noclip | Segment between samples crosses solid geometry ("Crossed"), or ends inside it ("Embedded") | 2.5 | `PassedThroughGeometry` |
| Fling | Root angular speed > 60 rad/s | 2 | `FlingDetected` |
| ExtremeVelocity | Horizontal > 300 or upward > 250 studs/s (downward ignored) | 2 | `ExtremeVelocity` |
| VelocityMismatch | Observed speed > 2.5 × reported velocity + 8, near or above the allowed speed | 1 | `VelocityMismatch` |

With defaults (threshold 5, half-life 10 s), the following get reported:

| Behaviour | Reported after |
|-----------|----------------|
| Sustained 2× speed | ~1–2 s |
| Two unauthorized teleports | ~10 s apart |
| Hovering | ~1 s past the jump arc |
| Air jumps | Two extra air jumps |
| Noclip | Two walls |

A single teleport, or a single wall crossed, is recorded as a violation but not reported.

**Allowed speed** = `max(server WalkSpeed, MinAllowedSpeed) × SpeedTolerance × multiplier +
platform speed × SpeedTolerance`. Games that change WalkSpeed on the server need no
configuration: client-side WalkSpeed changes never replicate, so the server value is the
authorized one.

## Legitimate movement handled

| Situation | Handling |
|-----------|----------|
| Respawn / character replacement | All movement state resets when `CharacterGeneration` changes |
| Seats and vehicles | Detectors pause while seated; history resets on leaving the seat |
| Death / ragdoll | Paused while dead |
| Climbing, swimming | Exempt from flight and air-jump checks |
| Falling | Speed is horizontal; downward motion never violates; long falls pass the flight check (they fall fast) |
| Moving platforms, trains, conveyors | Speed of the part underfoot is added to the allowed speed |
| Lag / packet bunching | Ping compensation (≤ 0.5 s) plus *time credit*: an unchanged position keeps its old timestamp, so a catch-up after a freeze is measured over the real elapsed time |
| Jumping | Flight allows a full jump arc from the server JumpPower/JumpHeight + 1 s; one rise per airtime is a normal jump |
| Double-jump games | `ModuleSettings.Movement.MaxAirJumps = 1` |
| Server teleports, dashes, jetpacks, knockback | The allowance API below |

These cases are covered by `tests/Specs/Integration/MovementLegit.spec.luau`.

## Allowance API

```lua
-- Right before the server moves a character (PivotTo, spawn points, portals):
ACF:AuthorizeTeleport(player)              -- 1 s window (pass seconds to change)
character:PivotTo(destination)

ACF:AllowMovement(player, "Speed", 2, { Multiplier = 3 })  -- dash / speed boost
ACF:AllowMovement(player, "Flight", 10)    -- jetpack, glider
ACF:AllowMovement(player, "Impulse", 1)    -- knockback, explosion, launch pad
ACF:AllowMovement(player, "Noclip", 5)     -- scripted phasing
ACF:AllowMovement(player, "All", 3)        -- cutscenes, admin tools
```

- **Teleport and Impulse** re-anchor history at the current position, so the displacement
  is never judged.
- **Speed** keeps covering the speed window for `MaxWindowSeconds` after it expires. That
  stops the window that still contains the fast samples from being flagged.

## Configuration

`ModuleSettings.Movement` (defaults):

| Key | Default | Key | Default |
|-----|---------|-----|---------|
| SampleIntervalSeconds | 0.2 | AirborneClearance | 1.5 |
| MinAllowedSpeed | 8 | MaxAirtimeExtraSeconds | 1 |
| SpeedTolerance | 1.25 | MinFallStudsPerSecond | 4 |
| SpeedSlackStuds | 4 | MaxAirJumps | 0 |
| MinWindowSeconds / MaxWindowSeconds | 0.5 / 2 | AirJumpRiseStuds | 3 |
| MaxPingCompensationSeconds | 0.5 | MaxHorizontalAcceleration | 600 |
| TeleportSlackStuds / TeleportMinDistance | 10 / 20 | NoclipMinDistance / NoclipMinThickness | 1 / 0.5 |
| VerticalSlackStuds / MaxVerticalPlatformSpeed | 8 / 25 | | |

Each module also has these tables:

- `Detectors.<Name>` (booleans): turn individual detectors on or off.
- `Severity.<Name>`: Speed 20, Teleport 30, Flight 30, InfiniteJump 25, Acceleration 10, Noclip 30.
- `Violation`: `HalfLifeSeconds` 10, `ReportThreshold` 5, `ReportIntervalSeconds` 10, `ConfidenceScale` 8.

`ModuleSettings.Physics` has the same tables, plus:

| Key | Default |
|-----|---------|
| MaxAngularSpeed | 60 |
| MaxHorizontalSpeed | 300 |
| MaxUpwardSpeed | 250 |
| MismatchRatio | 2.5 |
| MismatchSlack | 8 |
| MismatchMinFractionOfAllowed | 0.8 |
| Severity | Fling 35, ExtremeVelocity 25, VelocityMismatch 10 |
| Violation.ReportThreshold | 4 |

## Telemetry (optional, weak signal)

```lua
ACF:Initialize({ Modules = { Telemetry = true } })
```

The client script `StarterPlayerScripts.ACFTelemetry` (included in the Rojo projects) sends
`(sequence, fps)` every 5 s to `ReplicatedStorage.ACFRemotes.Telemetry`. That remote is
created by the server and protected by RemoteSecurity.

| Kind | Meaning | Defaults |
|------|---------|----------|
| `TelemetryMissing` | No heartbeat for 20 s, after a 30 s grace period | Severity 5, confidence ≤ 0.5, needs minutes of absence to report |
| `TelemetrySequence` | Sequence repeated or went backwards | Severity 10 |

**Be clear about what this proves.** An exploiter can delete the script or fire the remote
themselves. A *present* heartbeat proves nothing; only absence or malformation is weak
evidence. Lag and packet loss also cause absence, which is why the weight and confidence
are capped low. Never enforce on telemetry alone.

## Platform and testing notes

`Platform/RobloxPhysics.luau` samples via `HumanoidRootPart`, the first `Humanoid`, and
`workspace:Raycast`, excluding all player characters. Water counts as ground; R6 leg height
is accounted for. Under Lune the suite uses a fake world of boxes with Roblox ray semantics:
a ray starting inside a part does not hit it, which the Embedded noclip mode relies on.

The real probe is verified in Studio (TESTING.md): R6/R15/scaled rigs, seats, ladders,
water, moving platforms, morphs, and 50 characters at once.

**Server-controlled characters.** If ACF tracks bots or NPCs (via a custom players adapter),
pass their models so a character's own limbs never block its ground ray:
`RobloxPhysics.create({ GetCharacters = function() return myCharacters end })`.

Performance (Lune, `tools/bench.sh`): about 0.56 ms per tick for 50 players, including two
noclip ray casts per moving player. At 5 Hz that is roughly 0.3% of one core.
