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
| `Unit/` | One subsystem in isolation | CorePrimitives, Configuration, ModuleLoader, EvidenceManager |
| `Integration/` | Full framework with fakes | Framework (lifecycle, context, sessions, detection), ExampleDetector |
| `ExploitSimulation/` | Hostile inputs and misbehaving modules | Pipeline: floods, poisoned details, identity spoofing, rejoin reset |
| `Regression/` | One test per fixed bug, named after the bug | Created with the first reported bug |

Phase 1 result: **117/117 passing** under Lune 0.10.5; type check clean.

## What the offline harness cannot verify

Run these in Studio:

- Real `Players`/`RBXScriptSignal` behaviour: event ordering on join and leave, and
  `CharacterAdded` timing.
- `RunService.Heartbeat` cadence and `os.clock` precision on Roblox servers.
- `HttpService:GenerateGUID` and `DateTime` (used only by `RobloxEnvironment`).
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
