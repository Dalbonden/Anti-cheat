--[[
	Offline test entry point (Lune).

		./.bin/lune.exe run tests/lune/run.luau [filter]

	Builds the virtual DataModel from test.project.json and runs the same Runner that
	Studio uses (ServerStorage.ACFTests.Runner). Exits non-zero on any failure.
]]

local process = require("@lune/process")
local VirtualDataModel = require("./VirtualDataModel")

local root = process.cwd
local game, requireModule = VirtualDataModel.load(root .. "/test.project.json", root)

local filter = process.args[1]
local Runner = requireModule(game.ServerStorage.ACFTests.Runner)
local results = Runner.run({ Filter = filter })

process.exit(if results.Failed == 0 and results.Total > 0 then 0 else 1)
