--[[
	Every documented example configuration (examples/ConfigProfiles.luau) must boot. The
	configuration validator rejects unknown keys and out-of-range values, so a renamed or
	removed setting breaks this test instead of a user's upgrade.
]]

local ACF = game:GetService("ServerScriptService").ACF
local Framework = require(ACF.Core.Framework)
local Fakes = require(script.Parent.Parent.Fakes)
local Profiles = require(game:GetService("ServerStorage").ACFExamples.ConfigProfiles)

return function(t)
	local expect = t.expect

	t.describe("Example configuration profiles", function()
		local names = {}
		for name in Profiles do
			table.insert(names, name)
		end
		table.sort(names)
		for _, name in names do
			t.it(`{name} initialises and starts`, function()
				local fake = Fakes.environment()
				local framework = Framework.new(fake.Env)
				framework:Initialize(Profiles[name])
				framework:Start()
				expect(framework:GetState()).toBe("Running")
				framework:Destroy()
			end)
		end

		t.it("every profile starts in shadow mode or with enforcement off", function()
			for name, profile in Profiles do
				local enforcement = profile.Enforcement or {}
				if not (enforcement.ShadowMode == true or enforcement.Mode == "Off") then
					error({ __testFailure = true, message = `{name} would enforce out of the box` }, 0)
				end
			end
		end)
	end)
end
