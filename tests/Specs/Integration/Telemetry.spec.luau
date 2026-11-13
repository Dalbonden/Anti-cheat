local ACF = game:GetService("ServerScriptService").ACF
local Framework = require(ACF.Core.Framework)
local Fakes = require(script.Parent.Parent.Fakes)

local function setup(config)
	local fake = Fakes.environment()
	local framework = Framework.new(fake.Env)
	framework:Initialize(config or { Modules = { Telemetry = true } })
	framework:Start()
	local player = fake.Players:Join(Fakes.player(1))
	local remote = fake.Remotes.Created.Telemetry
	local world = { framework = framework, fake = fake, player = player, remote = remote }
	function world.advance(seconds)
		local steps = math.ceil(seconds / 1)
		for _ = 1, steps do
			fake.Clock.Advance(seconds / steps)
			framework:Step()
		end
	end
	function world.kinds()
		local kinds = {}
		for _, r in framework:GetEvidence(player) do
			kinds[r.Kind] = r
		end
		return kinds
	end
	return world
end

return function(t)
	local expect = t.expect

	t.describe("Telemetry", function()
		t.it("is disabled by default and creates no remote", function()
			local w = setup({})
			expect(w.framework:GetStatus().Modules.Telemetry.State).toBe("Disabled")
			expect(w.remote).toBeNil()
		end)

		t.it("creates and protects its remote when enabled", function()
			local w = setup()
			expect(w.remote ~= nil).toBe(true)
			local security = w.framework:GetModule("RemoteSecurity")
			expect(security:IsProtected(w.remote)).toBe(true)
		end)

		t.it("records heartbeats and FPS", function()
			local w = setup()
			Fakes.fire(w.remote, w.player, 1, 60)
			expect(w.framework:GetModule("Telemetry"):GetFps(w.player)).toBe(60)
		end)

		t.it("does not report players who send heartbeats", function()
			local w = setup()
			local sequence = 0
			for _ = 1, 60 do
				w.advance(5)
				sequence += 1
				Fakes.fire(w.remote, w.player, sequence, 60)
			end
			expect(w.kinds().TelemetryMissing).toBeNil()
			expect(w.kinds().TelemetrySequence).toBeNil()
		end)

		t.it("does not report a short outage", function()
			local w = setup()
			local sequence = 0
			for _ = 1, 10 do
				w.advance(5)
				sequence += 1
				Fakes.fire(w.remote, w.player, sequence, 60)
			end
			w.advance(40) -- lag spike / brief disconnect
			sequence += 1
			Fakes.fire(w.remote, w.player, sequence, 60)
			for _ = 1, 20 do
				w.advance(5)
				sequence += 1
				Fakes.fire(w.remote, w.player, sequence, 60)
			end
			expect(w.kinds().TelemetryMissing).toBeNil()
		end)

		t.it("reports a sustained missing heartbeat at low confidence", function()
			local w = setup()
			Fakes.fire(w.remote, w.player, 1, 60)
			w.advance(240)
			local record = w.kinds().TelemetryMissing
			expect(record ~= nil).toBe(true)
			expect(record.Category).toBe("Integrity")
			expect(record.Confidence <= 0.5).toBe(true)
			expect(record.Details.EverReceived).toBe(true)
		end)

		t.it("respects the startup grace period", function()
			local w = setup({ Modules = { Telemetry = true }, ModuleSettings = { Telemetry = { StartupGraceSeconds = 600 } } })
			w.advance(300)
			expect(w.kinds().TelemetryMissing).toBeNil()
		end)

		t.it("reports replayed or backwards sequences", function()
			local w = setup()
			Fakes.fire(w.remote, w.player, 10, 60)
			for _ = 1, 8 do
				Fakes.fire(w.remote, w.player, 10, 60)
				w.advance(5)
			end
			expect(w.kinds().TelemetrySequence ~= nil).toBe(true)
		end)

		t.it("rejects malformed heartbeats through RemoteSecurity", function()
			local w = setup()
			Fakes.fire(w.remote, w.player, "1", 60)
			Fakes.fire(w.remote, w.player, 1, 99999)
			Fakes.fire(w.remote, w.player, 0 / 0, 60)
			local stats = w.framework:GetModule("RemoteSecurity"):GetStats()["ACF.Telemetry"]
			expect(stats.Rejected.invalid_arguments).toBe(3)
			expect(stats.Accepted).toBe(0)
		end)

		t.it("fails cleanly without a remote provider", function()
			local fake = Fakes.environment()
			fake.Env.Remotes = nil
			local framework = Framework.new(fake.Env)
			framework:Initialize({ Modules = { Telemetry = true } })
			local status = framework:Start()
			expect(status.Modules.Telemetry.State).toBe("Failed")
			expect(status.State).toBe("Running")
		end)
	end)
end
