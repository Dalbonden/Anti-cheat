local ACF = game:GetService("ServerScriptService").ACF
local Framework = require(ACF.Core.Framework)
local V = require(ACF.Detection.RemoteSecurity.Validators)
local Policies = require(ACF.Detection.RemoteSecurity.Policies)
local Fakes = require(script.Parent.Parent.Fakes)

local function boot(config)
	local fake = Fakes.environment()
	local framework = Framework.new(fake.Env)
	framework:Initialize(config or {})
	local security = framework:GetModule("RemoteSecurity")
	return framework, fake, security
end

local function start(config)
	local framework, fake, security = boot(config)
	framework:Start()
	local player = fake.Players:Join(Fakes.player(1))
	return framework, fake, security, player
end

return function(t)
	local expect = t.expect

	t.describe("RemoteSecurity registration", function()
		t.it("is a built-in module that runs by default", function()
			local framework = start()
			expect(framework:GetStatus().Modules.RemoteSecurity.State).toBe("Running")
		end)

		t.it("can be disabled by configuration", function()
			local framework = boot({ Modules = { RemoteSecurity = false } })
			framework:Start()
			expect(framework:GetStatus().Modules.RemoteSecurity.State).toBe("Disabled")
		end)

		t.it("validates its configuration", function()
			local fake = Fakes.environment()
			local framework = Framework.new(fake.Env)
			expect(function()
				framework:Initialize({ ModuleSettings = { RemoteSecurity = { Suspicion = { HalfLifeSeconds = 0 } } } })
			end).toThrow("ModuleSettings.RemoteSecurity.Suspicion.HalfLifeSeconds")
		end)

		t.it("rejects invalid protection specs with clear messages", function()
			local _, _, security = boot()
			local remote = Fakes.remoteEvent("Buy")
			local function handler() end
			local cases = {
				{ nil, "spec must be a table" },
				{ { Arguments = {} }, "Handler function is required" },
				{ { Handler = handler }, "Arguments must be an array" },
				{ { Handler = handler, Arguments = { "string" } }, "Arguments[1] is not a validator" },
				{ { Handler = handler, Arguments = {}, Cooldwn = 1 }, "unknown spec field 'Cooldwn'" },
				{ { Handler = handler, Arguments = {}, RateLimit = { Burst = 0, PerSecond = 1 } }, "Burst >= 1" },
				{ { Handler = handler, Arguments = {}, Idempotency = { Argument = 1 } }, "must index one of the Arguments" },
				{ { Handler = handler, Arguments = { V.boolean() }, Idempotency = { Argument = 1 } }, "string or number" },
				{ { Handler = handler, Arguments = {}, RejectResponse = false }, "only applies to RemoteFunctions" },
				{ { Handler = handler, Arguments = {}, SuspicionWeights = { Typo = 1 } }, "unknown SuspicionWeights key" },
			}
			for _, case in cases do
				expect(function()
					security:ProtectEvent(remote, case[1])
				end).toThrow(case[2])
			end
		end)

		t.it("rejects the wrong remote class and double protection", function()
			local _, _, security = boot()
			local spec = { Arguments = {}, Handler = function() end }
			expect(function()
				security:ProtectEvent(Fakes.remoteFunction(), spec)
			end).toThrow("expects a RemoteEvent")
			expect(function()
				security:ProtectFunction(Fakes.remoteEvent(), spec)
			end).toThrow("expects a RemoteFunction")
			local remote = Fakes.remoteEvent()
			security:ProtectEvent(remote, spec)
			expect(function()
				security:ProtectEvent(remote, spec)
			end).toThrow("already protected")
		end)

		t.it("accepts UnreliableRemoteEvents", function()
			local _, _, security, player = start()
			local remote = Fakes.unreliableRemoteEvent("Aim")
			local calls = 0
			security:ProtectEvent(remote, {
				Arguments = { V.vector3() },
				Handler = function()
					calls += 1
				end,
			})
			Fakes.fire(remote, player, Fakes.vector3(1, 2, 3))
			expect(calls).toBe(1)
		end)
	end)

	t.describe("RemoteSecurity pipeline", function()
		t.it("passes validated arguments to the handler", function()
			local _, _, security, player = start()
			local remote = Fakes.remoteEvent("Buy")
			local received
			security:ProtectEvent(remote, {
				Arguments = { V.string(), V.integer({ Min = 1, Max = 99 }) },
				Handler = function(p, item, qty)
					received = { p, item, qty }
				end,
			})
			Fakes.fire(remote, player, "Sword", 3)
			expect(received[1]).toBe(player)
			expect(received[2]).toBe("Sword")
			expect(received[3]).toBe(3)
		end)

		t.it("rejects invalid arguments and extra arguments without calling the handler", function()
			local _, _, security, player = start()
			local remote = Fakes.remoteEvent("Buy")
			local calls = 0
			security:ProtectEvent(remote, {
				Arguments = { V.integer({ Min = 1, Max = 99 }) },
				Handler = function()
					calls += 1
				end,
			})
			Fakes.fire(remote, player, 1000)
			Fakes.fire(remote, player, "1")
			Fakes.fire(remote, player, 1, "extra")
			expect(calls).toBe(0)
			expect(security:GetStats().Buy.Rejected.invalid_arguments).toBe(3)
		end)

		t.it("lets optional trailing arguments be omitted", function()
			local _, _, security, player = start()
			local remote = Fakes.remoteEvent("Chat")
			local got
			security:ProtectEvent(remote, {
				Arguments = { V.string(), V.optional(V.string()) },
				Handler = function(_, a, b)
					got = { a, b }
				end,
			})
			Fakes.fire(remote, player, "hi")
			expect(got[1]).toBe("hi")
			expect(got[2]).toBeNil()
		end)

		t.it("rate limits per player and per remote", function()
			local _, fake, security, player = start()
			local other = fake.Players:Join(Fakes.player(2))
			local remote = Fakes.remoteEvent("Click")
			local calls = 0
			security:ProtectEvent(remote, {
				Arguments = {},
				RateLimit = { Burst = 3, PerSecond = 1 },
				Handler = function()
					calls += 1
				end,
			})
			for _ = 1, 10 do
				Fakes.fire(remote, player)
			end
			expect(calls).toBe(3)
			Fakes.fire(remote, other)
			expect(calls).toBe(4)
			fake.Clock.Advance(1)
			Fakes.fire(remote, player)
			expect(calls).toBe(5)
		end)

		t.it("uses the configured default rate limit", function()
			local _, _, security, player = start({ ModuleSettings = { RemoteSecurity = { DefaultRateLimit = { Burst = 2, PerSecond = 1 } } } })
			local remote = Fakes.remoteEvent("Click")
			local calls = 0
			security:ProtectEvent(remote, {
				Arguments = {},
				Handler = function()
					calls += 1
				end,
			})
			for _ = 1, 5 do
				Fakes.fire(remote, player)
			end
			expect(calls).toBe(2)
		end)

		t.it("enforces cooldown between accepted requests", function()
			local _, fake, security, player = start()
			local remote = Fakes.remoteEvent("Swing")
			local calls = 0
			security:ProtectEvent(remote, {
				Arguments = {},
				Cooldown = 1,
				Handler = function()
					calls += 1
				end,
			})
			Fakes.fire(remote, player)
			Fakes.fire(remote, player)
			fake.Clock.Advance(1)
			Fakes.fire(remote, player)
			expect(calls).toBe(2)
			expect(security:GetStats().Swing.Rejected.cooldown).toBe(1)
		end)

		t.it("applies permission and ownership checks", function()
			local _, _, security, player = start()
			local remote = Fakes.remoteEvent("EditPlot")
			local calls = 0
			local mine = Fakes.instance("Model", "Mine")
			mine:SetAttribute("OwnerUserId", 1)
			local theirs = Fakes.instance("Model", "Theirs")
			theirs:SetAttribute("OwnerUserId", 2)
			security:ProtectEvent(remote, {
				Arguments = { V.instance("Model") },
				Permission = Policies.Permissions.userIds({ 1 }),
				Ownership = Policies.Ownership.attribute(1, "OwnerUserId"),
				Handler = function()
					calls += 1
				end,
			})
			Fakes.fire(remote, player, mine)
			Fakes.fire(remote, player, theirs)
			expect(calls).toBe(1)
			expect(security:GetStats().EditPlot.Rejected.ownership_denied).toBe(1)
		end)

		t.it("denies the request when a policy check errors", function()
			local _, fake, security, player = start()
			local remote = Fakes.remoteEvent("Admin")
			local calls = 0
			security:ProtectEvent(remote, {
				Arguments = {},
				Permission = function()
					error("datastore down")
				end,
				Handler = function()
					calls += 1
				end,
			})
			Fakes.fire(remote, player)
			expect(calls).toBe(0)
			expect(#Fakes.findLogs(fake.Logs, "policy check errored", "Error")).toBe(1)
		end)

		t.it("rejects duplicate transaction ids inside the window", function()
			local _, fake, security, player = start()
			local remote = Fakes.remoteEvent("Purchase")
			local calls = 0
			security:ProtectEvent(remote, {
				Arguments = { V.string({ MaxLength = 36 }) },
				Idempotency = { Argument = 1, WindowSeconds = 10 },
				Handler = function()
					calls += 1
				end,
			})
			Fakes.fire(remote, player, "txn-1")
			Fakes.fire(remote, player, "txn-1")
			Fakes.fire(remote, player, "txn-2")
			expect(calls).toBe(2)
			fake.Clock.Advance(11)
			Fakes.fire(remote, player, "txn-1")
			expect(calls).toBe(3)
		end)

		t.it("keeps transaction memory bounded", function()
			local framework, _, security, player = start()
			local remote = Fakes.remoteEvent("Purchase")
			security:ProtectEvent(remote, {
				Arguments = { V.integer() },
				RateLimit = { Burst = 10000, PerSecond = 1000 },
				Idempotency = { Argument = 1, WindowSeconds = 60, MaxEntries = 8 },
				Handler = function() end,
			})
			for i = 1, 500 do
				Fakes.fire(remote, player, i)
			end
			expect(security:GetStats().Purchase.Accepted).toBe(500)
			local state = framework:GetSession(player):GetState("RemoteSecurity.State").Purchase
			expect(#state.idOrder <= 8).toBe(true)
			local stored = 0
			for _ in state.seenIds do
				stored += 1
			end
			expect(stored <= 8).toBe(true)
			-- The most recent id is still remembered and rejected as a duplicate.
			Fakes.fire(remote, player, 500)
			expect(security:GetStats().Purchase.Rejected.duplicate_transaction).toBe(1)
		end)

		t.it("requires a character when asked", function()
			local _, _, security, player = start()
			local remote = Fakes.remoteEvent("Jump")
			local calls = 0
			security:ProtectEvent(remote, {
				Arguments = {},
				RequireCharacter = true,
				Handler = function()
					calls += 1
				end,
			})
			Fakes.fire(remote, player)
			player:Spawn()
			Fakes.fire(remote, player)
			expect(calls).toBe(1)
		end)

		t.it("ignores requests from players without a session", function()
			local _, _, security = start()
			local remote = Fakes.remoteEvent("Buy")
			local calls = 0
			security:ProtectEvent(remote, {
				Arguments = {},
				Handler = function()
					calls += 1
				end,
			})
			Fakes.fire(remote, Fakes.player(99))
			expect(calls).toBe(0)
			expect(security:GetStats().Buy.Rejected.no_session).toBe(1)
		end)

		t.it("isolates handler errors", function()
			local _, fake, security, player = start()
			local remote = Fakes.remoteEvent("Buggy")
			security:ProtectEvent(remote, {
				Arguments = {},
				Handler = function()
					error("game bug")
				end,
			})
			expect(function()
				Fakes.fire(remote, player)
			end).never.toThrow()
			expect(security:GetStats().Buggy.HandlerErrors).toBe(1)
			expect(#Fakes.findLogs(fake.Logs, "Remote handler errored", "Error")).toBe(1)
		end)
	end)

	t.describe("RemoteSecurity functions", function()
		t.it("returns handler results for valid calls and RejectResponse otherwise", function()
			local _, _, security, player = start()
			local remote = Fakes.remoteFunction("GetPrice")
			security:ProtectFunction(remote, {
				Arguments = { V.string({ MaxLength = 16 }) },
				RejectResponse = false,
				Handler = function(_, item)
					return item == "Sword", 100
				end,
			})
			local ok, price = Fakes.invoke(remote, player, "Sword")
			expect(ok).toBe(true)
			expect(price).toBe(100)
			expect(Fakes.invoke(remote, player, 42)).toBe(false)
		end)

		t.it("returns RejectResponse when the handler errors", function()
			local _, _, security, player = start()
			local remote = Fakes.remoteFunction("Broken")
			security:ProtectFunction(remote, {
				Arguments = {},
				RejectResponse = "error",
				Handler = function()
					error("bug")
				end,
			})
			expect(Fakes.invoke(remote, player)).toBe("error")
		end)
	end)

	t.describe("RemoteSecurity lifecycle", function()
		t.it("protections made before Start activate on Start", function()
			local framework, fake, security = boot()
			local remote = Fakes.remoteEvent("Early")
			local calls = 0
			security:ProtectEvent(remote, {
				Arguments = {},
				Handler = function()
					calls += 1
				end,
			})
			framework:Start()
			local player = fake.Players:Join(Fakes.player(1))
			Fakes.fire(remote, player)
			expect(calls).toBe(1)
		end)

		t.it("fails closed while stopped and resumes on restart", function()
			local framework, fake, security, player = start()
			local event = Fakes.remoteEvent("E")
			local fn = Fakes.remoteFunction("F")
			local calls = 0
			security:ProtectEvent(event, {
				Arguments = {},
				Handler = function()
					calls += 1
				end,
			})
			security:ProtectFunction(fn, {
				Arguments = {},
				RejectResponse = "closed",
				Handler = function()
					return "open"
				end,
			})
			framework:Stop()
			Fakes.fire(event, player)
			expect(calls).toBe(0)
			expect(Fakes.invoke(fn, player)).toBe("closed")
			framework:Start()
			fake.Players:Join(player)
			Fakes.fire(event, player)
			expect(calls).toBe(1)
			expect(Fakes.invoke(fn, player)).toBe("open")
		end)

		t.it("unprotect removes the handler", function()
			local _, _, security, player = start()
			local event = Fakes.remoteEvent("E")
			local calls = 0
			local handle = security:ProtectEvent(event, {
				Arguments = {},
				Handler = function()
					calls += 1
				end,
			})
			handle.Unprotect()
			Fakes.fire(event, player)
			expect(calls).toBe(0)
			expect(security:IsProtected(event)).toBe(false)
		end)

		t.it("finds unprotected remotes", function()
			local _, _, security = start()
			local root = Fakes.instance("Folder", "Remotes")
			local protectedRemote = Fakes.instance("RemoteEvent", "Safe", root)
			local open = Fakes.instance("RemoteEvent", "Open", root)
			local openFn = Fakes.instance("RemoteFunction", "OpenFn", root)
			Fakes.instance("Folder", "NotARemote", root)
			security:ProtectEvent(protectedRemote, { Arguments = {}, Handler = function() end })
			local found = security:FindUnprotected(root)
			expect(#found).toBe(2)
			expect(table.find(found, open) ~= nil).toBe(true)
			expect(table.find(found, openFn) ~= nil).toBe(true)
		end)
	end)
end
