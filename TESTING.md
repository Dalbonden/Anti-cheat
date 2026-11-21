# Testing ACF

## Running

```bash
tools/test.sh               # all tests under Lune
tools/test.sh Evidence      # only tests whose full name contains "Evidence"
tools/check.sh              # strict static type check (luau-lsp + Roblox definitions)
```

**In Roblox Studio:** run `tools/build.sh`, open `build/ACF-Tests.rbxl` (or `rojo serve
test.project.json`), then in the command bar:

```lua
require(game:GetService("ServerStorage").ACFTests.Runner).run()
```

The same spec files run in both environments.

## How it works

`tests/lune/VirtualDataModel.luau` reads `test.project.json` and builds a virtual instance
tree. Its `require(instance)` executes ModuleScripts with `script`, `game` and `task`
provided, so ACF source runs unmodified. Platform services come from `tests/Specs/Fakes.luau`
through ACF's `Environment`:

- fake Players service and players;
- a manually advanced clock;
- a fake Heartbeat;
- deterministic ids;
- a capturing log sink.

Tests advance time with `fake.Clock.Advance(seconds)` and drive scheduled work with
`framework:Step()`. That makes time-dependent behaviour (rate limits, expiry, intervals)
deterministic.

## Suites

| Folder | Purpose | Current |
|--------|---------|---------|
| `Unit/` | One subsystem in isolation | CorePrimitives, Configuration, ModuleLoader, EvidenceManager, Validators (+ Policies), MovementDetectors (+ ViolationTracker), CombatRules, Statistics, BehavioralDetectors, RiskModel, EnforcementPolicy (+ BanRecords) |
| `Integration/` | Full framework with fakes | Framework (lifecycle, context, sessions, detection), ExampleDetector, RemoteSecurity, **MovementLegit** (19 legitimate-play scenarios that must produce no evidence), Telemetry, **CombatLegit** (16 legitimate-combat scenarios), CombatHarness (shared arena), **BehavioralLegit** (10 legitimate-behaviour scenarios), BehavioralHarness (N-player world, deterministic RNG), Risk (formula, decay, suppression, correlation, bands, history, bounds, end to end), RiskPersistence (shared fake Store across "servers": saving, seeding, caps, failures, latency races, batching, shutdown), Enforcement (restriction, correction, cases, automatic and approved removals, escalation, shadow/Off/Manual modes, bans across servers, storage and ban-API failures, overrides, audit) |
| `ExploitSimulation/` | Hostile inputs and misbehaving modules | Pipeline (floods, poisoned details, spoofing, rejoin reset); Remotes (type confusion, huge/deep tables, forged instances, replay, suspicion vs. honest lag); Movement (speed, teleport, flight, air jump, noclip, acceleration, fling, tp-walk); Combat (rapid fire, infinite ammo, unowned/fabricated weapons, reach, wall-bang, origin spoof, silent aim, cooldown bypass, instant/magic/replayed projectiles, dead shooter, malformed claims); Behavioral (currency exploits incl. colluding, aimbot, head-lock, autoclickers and their documented limits, invalid floods, hostile API input) |
| `Regression/` | One test per fixed bug, named after the bug | Created with the first reported bug |

Current result (v1.0.0): **426/426 passing** under Lune 0.10.5 and in Roblox Studio's VM
(0.748); type check clean.

**Phase 8 suites:**

- `Integration/Population` runs a 4-minute server with honest players and every cheat.
- `Integration/Latency` sweeps honest populations from 0.02 s to 0.9 s ping.
- `tools/evaluate.sh` runs the long evaluation; results are in `docs/EVALUATION.md`.
- The simulator is `tests/Specs/Simulation.luau`: seeded and deterministic, with clicks
  at 60 Hz frame times, not tick-aligned.

**False-positive policy.** Every movement, physics, combat or behavioural detector change
must keep `Integration/MovementLegit`, `Integration/CombatLegit` and
`Integration/BehavioralLegit` clean. A legitimate scenario that
produces evidence is a bug in the detector, not in the test.

**Mutation spot checks.** For each new detector, break its core check and confirm that an
exploit test fails. Then make its tolerance zero and confirm that a legitimate test fails.
That proves the suites are not vacuous.

- Phase 4 did this for origin and hit-tolerance.
- Phase 5 did it for the median baseline, the z clamp, the Wilson bound, the MinRatio
  guard, idle-bucket counting and the timing check.
- Phase 6 did it for correlation, saturation, duplicate suppression, confidence
  weighting, the stale-load guard, the history cap, the save threshold and save retries.
- Phase 7 did it for statistical corroboration, unapproved permanent bans, shadow mode,
  the new-evidence guard, the join ban check, exempt overrides and the temporary
  restriction.

**Enforcement fakes.** `Fakes.enforcer(players)` records `Kicks`, `Bans` and `Unbans`.
Kick makes the player leave, like Roblox does, and `FailBans` injects ban-API failures.
`Fakes.physics():Correct` records corrections.

**Storage fakes.** `Fakes.store()` is an in-memory `Environment.Store`:

- `Deferred = true` holds callbacks until `Complete()`, modelling DataStore latency;
- `FailLoads` / `FailSaves` inject failures;
- pass one store to several `Fakes.environment({ Store = s, ClockStart = t })` calls to
  simulate the same player on different servers at different times.

**Behavioural scenarios are deterministic.** `BehavioralHarness.rng(seed)` is a Park-Miller
generator, so a "random" honest population is identical on every run, in Lune and in Studio.

## Fakes and Roblox types

`Fakes.physics()` (included in `Fakes.environment()`) is a world of boxes with Roblox ray
semantics: a ray starting inside a part does not hit it. Character samples are scripted
with `fake.Physics:Set(character, fields)`, and ground clearance is computed from the boxes
below unless set explicitly.

`Fakes.instance`, `Fakes.vector3` and `Fakes.cframe` return **real** engine objects when
the suite runs in Studio. Under Lune they return tables, and the harness `typeof` reports
them as `Instance`/`Vector3`/`CFrame`. `Fakes.remoteEvent`/`remoteFunction` are always
fakes, because a real remote cannot be fired from the server. `Fakes.fire(remote, player,
...)` and `Fakes.invoke(...)` simulate client requests.

## Benchmarks

`tools/bench.sh` times hot paths under Lune. Use it to spot regressions, not to predict
Roblox server costs.

## Studio verification log

**2026-11-17**, Roblox Studio (scratch place, R15 character), v0.4.0:

**Full suite in Edit mode:** 278/278 passing in Roblox's own Luau VM. The fakes switch to
real `Instance`, `Vector3` and `CFrame` objects there.

**Live Play mode,** with ACF started via the real `RobloxEnvironment` (Players, Heartbeat,
RobloxPhysics):

| Area | Result |
|------|--------|
| Real probe on a standing R15 character | `GroundClearance` 0.004, JumpVelocity 53.15 (JumpHeight 7.2), State Running, WalkSpeed 16 |
| Idle character, and an authorized 250-stud server teleport | No detections |
| Three unauthorized 300-stud teleports | `TeleportDetected` reported (allowed 26 studs in 0.8 s) |
| Hovering 57 studs up (anchored root) | `Flight` reported after 2.6 s of airtime (allowed 1.54 s) |
| Movement sampler cost | 187 runs, 0 failures, ~0.08 ms per tick with 1 player |
| Combat with real raycasts and `Describe` against an NPC dummy | Body hit 25 and headshot 50 allowed; shot through a wall refused (`NoLineOfSight`); 190-stud shot refused (`OutOfRange`) |
| RemoteSecurity over the real network, fired from the Studio client | The valid request reached the handler. NaN, a 5,000-character string, a table instead of a string, and an extra argument were all rejected. A 30-request flood was rate-limited (29). Both patterns were reported as evidence. |

**Second session, same day** (test map built inside Play mode, so it vanished on Stop):

| Case | Result |
|------|--------|
| R6 and R15 NPC rigs on the baseplate | `GroundClearance` 0.000 for both. R6 HipHeight 0 is handled by the leg compensation; R15 has HipHeight 2.19. |
| Seat / vehicle | Seated via `Seat:Sit`, the seat moved 300 studs at 100 studs/s, then exited. No detections. |
| Moving platform | A conveyor carried the character at 41.6 studs/s (2.6× WalkSpeed). The probe read `GroundSpeed` = 40 on every sample. No detections. |
| Ladder | The client climbed a truss wall to y = 83 (Climbing state replicated), went over the top and fell 80 studs. No detections. |
| Terrain water | Swam in circles for 8 s. The server saw state `Swimming` and clearance 0 (water counts as ground). No detections. |
| Accessory hits | Hats resolve to the wearer's model. **Gap found:** hats counted as body shots. Fixed in `RobloxPhysics.Describe`: a Handle welded to the Head, or carrying a Hat/Hair/Face attachment, counts as head. Re-verified live: a proper AccessoryWeld hat and a WeldConstraint hat are head; a back accessory is not; a shot at the hat did 50 damage (2× headshot). |

**NPC load test, 2026-11-19** (ACF's own test place, Play mode). An isolated ACF instance
ran with a players adapter that presents 50 real R15 NPC rigs as players, plus the real
`RobloxPhysics`, raycasts and Heartbeat:

- 48 honest bots wandered and jumped across a 1024-stud map;
- 20 of them fired hitscan claims through Combat 4 times a second at the nearest bot;
- Bot1 teleported between two on-map points every 3 s;
- Bot2 hovered 40 studs up.

| Measure (60 s) | Result |
|----------------|--------|
| Movement + Physics sampling, 50 characters | 352 ticks, 0 failures, **1.43 ms average / 2.89 ms max per tick** (~0.7% of a core at 5 Hz) |
| Combat with real raycasts | 5,100 validated hits, all legitimate, all allowed; **~37 µs each** |
| Memory | Flat, 7.6–11.4 MB sawtooth over 60 s |
| Errors / warnings | 0 |
| Cheaters | Bot1 `TeleportDetected` and Bot2 `Flight`, reported continuously |
| Honest bots flagged | **0** |

A first attempt let random teleports carry Bot1 off the map, where it died after one jump;
ACF correctly didn't report a single teleport. Another bot fell under the floor while the
harness kept it shooting, and ACF correctly refused those shots as `NoLineOfSight`. Both
were harness bugs. The harness was then fixed to keep bots on the map.

**Morph test** (real player): the character was replaced four times by setting
`Player.Character`, with no allowance granted:

- R15 → R6 (280 studs away);
- → a 1.5×-scaled custom R15 (470 away);
- → R15 while walking (450 away);
- then a 70-stud walk.

`CharacterGeneration` incremented on every morph, `GroundClearance` was 0.00 for every rig,
and there were **zero detections**. Three unauthorized teleports on the morphed character
were then reported as `TeleportDetected`, so morphing does not blind ACF.

**Still requires real clients:** network-level load, meaning many clients' remote traffic,
client-owned physics and latency (Test → Clients and Servers, or a live server). Phase 8.

**Phase 8, 2026-11-20** (Studio 0.748, ACF's own test place, real `RobloxEnvironment`):

| Check | Result |
|-------|--------|
| Full suite in the Roblox VM | 420/420 in 2.7 s |
| DataStore in an unpublished place | Every call fails. Risk continues without history; enforcement retries 5×, then audits `PersistenceFailed`. No crash. |
| Movement correction, server-side teleport | 150-stud jumps pulled back to the anchor within 0.8 s; the client sees the corrected position |
| Movement correction, **client-side** teleport (as an exploit does it) | Pulled back after 0.25–0.28 s, 3/3. `TeleportDetected` evidence each time. |
| Idle-then-teleport (63 studs after ~60 s still) | **Not detected: bug found.** Fixed with `MaxTimeCreditSeconds`; regression test added. |
| Latency, Network Simulator 120±40 ms each way + 0.5 % loss | Measured NetworkPing 278 ms. 45 s of walking and 31 jumps: no evidence. |
| Latency, 350±120 ms each way | Measured 790 ms. 45 s, 24 jumps: no evidence. A client teleport at this ping was still detected (325 studs, 24 allowed). |
| `ACF:Kick` | `Player:Kick` → `PlayerRemoving` after 1.1 s; session ended; audit names the staff member |
| `ACF:Ban` → `Players:BanAsync` | Returns success instantly in an unpublished place (PlaceId 0) and does nothing; `GetBanHistoryAsync` 403. **Needs a published game to verify.** |

The Network Simulator settings were read before the test (all 0) and restored afterwards.

**Staff tooling, 2026-11-21** (Studio 0.748, ACF's test place with TextChatService; the
example scripts installed as a game would install them, ACF started by a game Script):

| Check | Result |
|-------|--------|
| New case announced to staff | Case opened by a probe detection; the staff client received `[ACF] Case ACF-… needs review` |
| `/acf cases`, `/acf case <id>` | Listed the case; returned its reason and explanation |
| `/acf reject <id> <note>` | Case `Rejected`, `DecidedBy` = staff name and UserId; `CaseRejected` audited |
| `/acf exempt <player> 5` | Override exempt, level Logging; `OverrideSet` audited with the staff name |
| `Player.Chatted` under legacy chat | Not fired for messages sent through the chat remote from the test client; the docs say it fires for typed messages via the default chat script. The example uses TextChatCommand and keeps `Chatted` only as the legacy fallback. |
| `AuditToDataStore` in an unpublished place | **Bug found:** `GetDataStore` threw and the script died. Fixed: it now warns and leaves the audit in memory. |

Two Studio quirks met along the way:

- **The plugin runs in its own Luau VM.** `require(ServerScriptService.ACF)` from
  `execute_luau` returns a *separate* instance, `State = Created`. Live tests of a game's
  own ACF go through a BindableFunction bridge.
- **`ChatVersion` can only be set at build time.** `test.project.json` now sets
  TextChatService.

## Regression register

Every bug fixed after it was found, and the test that now guards it:

| Bug | Found by | Guarded by |
|-----|----------|------------|
| Noclip rays starting inside a part didn't hit it | Phase 3 | `ExploitSimulation/Movement` (Embedded mode) |
| Dash allowance expiry flagged the window that still held fast samples | Phase 3 | `MovementLegit` "a game dash…" |
| Knockback looked like a teleport | Phase 3 | `MovementLegit` "knockback…" |
| Moving platforms flagged as speed | Phase 3 | `MovementLegit` "riding a moving train…" |
| Projectiles assumed a straight path (lobs flagged `OffTrajectory`) | Phase 4 | `CombatLegit` gravity arc |
| Combat methods invisible to strict type checking | Phase 4 | `tools/check.sh` in `tools/verify.sh` |
| Hats counted as body shots | Phase 4, Studio | Studio check (`RobloxPhysics.Describe`), TESTING log 2026-11-17 |
| NPC limbs blocked their own ground ray | Phase 4, Studio | `RobloxPhysics.create({ GetCharacters })`, Studio NPC load test |
| Lump earners flagged (active-bucket rates) | Phase 5 design | `BehavioralLegit` "an honest economy…"; `Unit/BehavioralDetectors` |
| 2× gamepass owners flagged (MinRatio 2) | Phase 5 design | `BehavioralLegit`; mutation check |
| A kick's own detection cleared the new-evidence guard (re-kick on rejoin) | Phase 7 | `Enforcement` "…waits for new evidence after rejoin" |
| Offline ban records saved only on the next tick | Phase 7 | `Enforcement` "bans persist across servers…" |
| Bans waited for the stored record before removing the player | Phase 7 | `Enforcement` "a ban takes effect immediately…" |
| Lag spike mid-jump looked like flight | Phase 8 simulation | `MovementLegit` "lag: a 2.8 s freeze in mid-air…" |
| Spoofed velocity could hover forever under stall credit | Phase 8 design | `ExploitSimulation/Movement` "hovering while spoofing velocity…" |
| Uncapped time credit: idle then teleport | Phase 8 Studio | `ExploitSimulation/Movement` "standing still for a minute…" |
| Forgotten players re-created by decaying risk | Phase 8 soak | `Enforcement` "a forgotten player's decaying risk…" |
| Review cases opened while risk decayed or after leaving | Phase 8 soak | same test |
| Without a Store, pruning could drop the only copy of a ban | Phase 8 review | `Enforcement` "without a Store, ban records are never forgotten" |
| Example config keys can go stale | Docs review | `Unit/ConfigProfiles` boots every documented profile |

New bugs get a test here first. Write one that fails, then fix the bug.

## What the offline harness cannot verify

Run these in Studio:

- Real `Players`/`RBXScriptSignal` behaviour: event ordering on join and leave, and
  `CharacterAdded` timing.
- `RunService.Heartbeat` cadence and `os.clock` precision on Roblox servers.
- `HttpService:GenerateGUID` and `DateTime` (used only by `RobloxEnvironment`).
- `Platform/RobloxPhysics`, the real character probe:
  - R6/R15 ground clearance;
  - `Humanoid:GetState()` replication for client-owned characters;
  - terrain water;
  - the moving-platform `GroundSpeed`;
  - ray cast exclusions.
- Real remote traffic: argument marshalling (metatables stripped, Instance references
  that don't replicate arrive as nil), `OnServerInvoke` behaviour and real client timing.
- Performance under real load (Phase 8: multiplayer load, latency and DataStore failure
  tests).

## Writing tests

```lua
-- tests/Specs/Unit/MyThing.spec.luau
local ACF = game:GetService("ServerScriptService").ACF
local Fakes = require(script.Parent.Parent.Fakes)

return function(t)
    t.describe("MyThing", function()
        t.it("does the thing", function()
            t.expect(1 + 1).toBe(2)
        end)
    end)
end
```

Files must end in `.spec.luau`. Matchers include `toBe`, `toEqual`, `toBeNil`, `toBeTruthy`,
`toBeFalsy`, `toBeGreaterThan`, `toBeLessThan`, `toBeCloseTo`, `toContain`, `toHaveLength`,
`toThrow` and `never.*`.

Never mark a test as passing without running it. If a test depends on something only
Studio provides, say so in the test name and in this file.
