--[[
	Micro-benchmarks for hot paths (Lune). Numbers are indicative only: Lune's Luau VM
	is not Roblox's server, but relative costs and regressions show up reliably.

		./.bin/lune.exe run tests/lune/bench.luau
]]

local process = require("@lune/process")
local VirtualDataModel = require("./VirtualDataModel")

local root = process.cwd
local game, requireModule = VirtualDataModel.load(root .. "/test.project.json", root)
local ACF = game.ServerScriptService.ACF
local Framework = requireModule(ACF.Core.Framework)
local V = requireModule(ACF.Detection.RemoteSecurity.Validators)
local Fakes = requireModule(game.ServerStorage.ACFTests.Fakes)

local function bench(name: string, iterations: number, fn: () -> ())
	for _ = 1, math.min(1000, iterations) do
		fn()
	end
	local started = os.clock()
	for _ = 1, iterations do
		fn()
	end
	local elapsed = os.clock() - started
	print(string.format("%-46s %9.2f us/op  (%d ops)", name, elapsed / iterations * 1e6, iterations))
end

local fake = Fakes.environment()
local framework = Framework.new(fake.Env)
framework:Initialize({})
framework:Start()
local security = framework:GetModule("RemoteSecurity")
local player = fake.Players:Join(Fakes.player(1))

local buy = Fakes.remoteEvent("Buy")
security:ProtectEvent(buy, {
	Arguments = { V.string({ MaxLength = 32 }), V.integer({ Min = 1, Max = 99 }) },
	RateLimit = { Burst = 1e9, PerSecond = 1e9 },
	Handler = function() end,
})

local inventory = Fakes.remoteEvent("Inventory")
security:ProtectEvent(inventory, {
	Arguments = { V.array(V.struct({ Id = V.string({ MaxLength = 16 }), Count = V.integer() }), { MaxLength = 32 }) },
	RateLimit = { Burst = 1e9, PerSecond = 1e9 },
	Handler = function() end,
})
local items = {}
for i = 1, 32 do
	items[i] = { Id = "item" .. i, Count = i }
end

local flooded = Fakes.remoteEvent("Flooded")
security:ProtectEvent(flooded, {
	Arguments = {},
	RateLimit = { Burst = 1, PerSecond = 0.001 },
	Handler = function() end,
})

local huge = table.create(100000, 1)

bench("accepted request (2 scalar args)", 200000, function()
	Fakes.fire(buy, player, "Sword", 3)
end)
bench("accepted request (array of 32 structs)", 50000, function()
	Fakes.fire(inventory, player, items)
end)
bench("rejected: invalid argument", 200000, function()
	Fakes.fire(buy, player, "Sword", -1)
end)
bench("rejected: rate limited (flood)", 200000, function()
	Fakes.fire(flooded, player)
end)
bench("rejected: 100k-element table (bounded walk)", 20000, function()
	Fakes.fire(inventory, player, huge)
end)

local evidence = framework:GetEvidenceSummary(player)
print(string.format("\nevidence records after flood: %d (merged %d)", evidence.Records, evidence.Merged))
