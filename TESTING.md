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
