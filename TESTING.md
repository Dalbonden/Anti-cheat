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
| `Unit/` | One subsystem in isolation | CorePrimitives, Configuration, ModuleLoader, EvidenceManager, Validators (+ Policies), MovementDetectors (+ ViolationTracker) |
| `Integration/` | Full framework with fakes | Framework (lifecycle, context, sessions, detection), ExampleDetector, RemoteSecurity, **MovementLegit** (19 legitimate-play scenarios that must produce no evidence), Telemetry, **CombatLegit** (16 legitimate-combat scenarios), CombatHarness (shared arena) |
| `ExploitSimulation/` | Hostile inputs and misbehaving modules | Pipeline (floods, poisoned details, spoofing, rejoin reset); Remotes (type confusion, huge/deep tables, forged instances, replay, suspicion vs. honest lag); Movement (speed, teleport, flight, air jump, noclip, acceleration, fling, tp-walk); Combat (rapid fire, infinite ammo, unowned/fabricated weapons, reach, wall-bang, origin spoof, silent aim, cooldown bypass, instant/magic/replayed projectiles, dead shooter, malformed claims) |
| `Regression/` | One test per fixed bug, named after the bug | Created with the first reported bug |

Current result (v0.4.0): **278/278 passing** under Lune 0.10.5; type check clean.

**False-positive policy.** Every movement, physics or combat detector change must keep
`Integration/MovementLegit` and `Integration/CombatLegit` clean. A legitimate scenario that
produces evidence is a bug in the detector, not in the test.

**Mutation spot checks.** For each new detector, break its core check and confirm that an
exploit test fails. Then make its tolerance zero and confirm that a legitimate test fails.
That proves the suites are not vacuous. Phase 4 did this for origin and hit-tolerance.

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

**Not yet verified in Studio:** multiplayer load. That needs a multi-client test server
(Test → Clients and Servers) or a live server, and belongs to Phase 8.

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
