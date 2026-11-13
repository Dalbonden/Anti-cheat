--[[
	Runs every "*.spec" ModuleScript under this folder. Shared by the Lune entry point
	(tests/lune/run.luau) and Studio:

		require(game:GetService("ServerStorage").ACFTests.Runner).run()
]]

local TestKit = require(script.Parent.TestKit)

local Runner = {}

function Runner.run(options: { Filter: string?, Print: ((string) -> ())? }?)
	local specs = {}
	for _, descendant in script.Parent:GetDescendants() do
		local name = descendant.Name
		if descendant:IsA("ModuleScript") and string.sub(name, -5) == ".spec" then
			table.insert(specs, {
				name = `{descendant.Parent.Name}/{string.sub(name, 1, -6)}`,
				spec = require(descendant),
			})
		end
	end
	table.sort(specs, function(a, b)
		return a.name < b.name
	end)
	return TestKit.run(specs, options)
end

return Runner
