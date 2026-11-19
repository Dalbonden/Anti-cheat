local ACF = game:GetService("ServerScriptService").ACF
local Framework = require(ACF.Core.Framework)
local Topics = require(ACF.Core.Topics)
local Configuration = require(ACF.Core.Configuration)
local Fakes = require(script.Parent.Parent.Fakes)

local S = Configuration.Schema

local function boot(config, modules, options)
	local fake = Fakes.environment(options)
	local framework = Framework.new(fake.Env)
	framework:Initialize(config)
	for _, def in modules or {} do
		framework:RegisterModule(def)
	end
	return framework, fake
end

return function(t)
	local expect = t.expect

	t.describe("Framework lifecycle", function()
		t.it("moves through Created, Initialized, Running, Stopped, Destroyed", function()
			local fake = Fakes.environment()
			local framework = Framework.new(fake.Env)
			local seen = {}
			expect(framework:GetState()).toBe("Created")
			framework:Initialize({})
			framework:Subscribe(Topics.FrameworkStateChanged, function(p)
				table.insert(seen, p.To)
			end)
			framework:Start()
			framework:Stop()
			framework:Start()
			framework:Destroy()
			expect(seen).toEqual({ "Running", "Stopped", "Running", "Stopped" })
			expect(framework:GetState()).toBe("Destroyed")
		end)

		t.it("rejects calls in the wrong state", function()
			local fake = Fakes.environment()
			local framework = Framework.new(fake.Env)
			expect(function()
				framework:Start()
			end).toThrow("requires state Initialized")
			framework:Initialize({})
			expect(function()
				framework:Initialize({})
			end).toThrow("only be called once")
		end)

		t.it("raises a readable error on invalid configuration and allows a retry", function()
			local fake = Fakes.environment()
			local framework = Framework.new(fake.Env)
			expect(function()
				framework:Initialize({ LogLevel = "Loud", Evidence = { MaxRecordsPerPlayer = -1 } })
			end).toThrow("ACF configuration is invalid")
			expect(framework:GetState()).toBe("Created")
			framework:Initialize({})
			expect(framework:GetState()).toBe("Initialized")
		end)

		t.it("validates the environment", function()
			expect(function()
				Framework.new({} :: any)
			end).toThrow("Environment.Players")
		end)

		t.it("queues modules registered before Initialize", function()
			local fake = Fakes.environment()
			local framework = Framework.new(fake.Env)
			local def = Fakes.module("Early")
			framework:RegisterModule(def)
			framework:Initialize({})
			framework:Start()
			expect(def.Calls).toEqual({ "Initialize", "Start" })
		end)

		t.it("refuses module registration after the first Start", function()
			local framework = boot({})
			framework:Start()
			expect(function()
				framework:RegisterModule(Fakes.module("Late"))
			end).toThrow("before the first Start")
		end)

		t.it("honours the Modules enable map and EnabledByDefault", function()
			local on = Fakes.module("On")
			local off = Fakes.module("Off")
			local optIn = Fakes.module("OptIn", { EnabledByDefault = false })
			local framework = boot({ Modules = { Off = false } }, { on, off, optIn })
			local status = framework:Start()
			expect(status.Modules.On.State).toBe("Running")
			expect(status.Modules.Off.State).toBe("Disabled")
			expect(status.Modules.OptIn.State).toBe("Disabled")
		end)

		t.it("warns about configured modules that are not registered", function()
			-- Economy was announced for Phase 5 and shipped as Behavioral signals instead.
			local framework, fake = boot({ Modules = { Economy = true } })
			framework:Start()
			local warnings = Fakes.findLogs(fake.Logs, "Configured module is not registered", "Warn")
			expect(#warnings).toBe(1)
			expect(warnings[1].Fields.Module).toBe("Economy")
			expect(#Fakes.findLogs(fake.Logs, "not available in this ACF version", "Warn")).toBe(0)
		end)

		t.it("fails Start when a Critical module cannot start, and stops the others", function()
			local healthy = Fakes.module("Healthy")
			local critical = Fakes.module("Core1", {
				Critical = true,
				Start = function()
					error("hard dependency missing")
				end,
			})
			local framework = boot({}, { healthy, critical })
			expect(function()
				framework:Start()
			end).toThrow("critical modules failed to start")
			expect(framework:GetState()).toBe("Initialized")
			expect(framework:GetStatus().Modules.Healthy.State).toBe("Stopped")
		end)

		t.it("survives a non-critical module failing", function()
			local broken = Fakes.module("Broken", {
				Initialize = function()
					error("bug")
				end,
			})
			local framework = boot({}, { broken, Fakes.module("Fine") })
			local status = framework:Start()
			expect(status.State).toBe("Running")
			expect(status.Modules.Broken.State).toBe("Failed")
			expect(status.Modules.Fine.State).toBe("Running")
		end)

		t.it("validates module configuration at registration", function()
			local def = Fakes.module("Speed", { ConfigSchema = S.Table({ Max = S.Number(16, { Min = 0 }) }) })
			local fake = Fakes.environment()
			local framework = Framework.new(fake.Env)
			framework:Initialize({ ModuleSettings = { Speed = { Max = -5 } } })
			expect(function()
				framework:RegisterModule(def)
			end).toThrow("ModuleSettings.Speed.Max")
		end)

		t.it("delivers validated module configuration through the context", function()
			local def = Fakes.module("Speed", { ConfigSchema = S.Table({ Max = S.Number(16) }) })
			local framework = boot({ ModuleSettings = { Speed = { Max = 20 } } }, { def })
			framework:Start()
			expect(def.Context.Config.Max).toBe(20)
			expect(table.isfrozen(def.Context.Config)).toBe(true)
		end)

		t.it("rejects settings for modules that never registered", function()
			local framework = boot({ ModuleSettings = { Sped = { Max = 1 } } })
			expect(function()
				framework:Start()
			end).toThrow("ModuleSettings.Sped")
		end)

		t.it("drives the scheduler from the heartbeat when one is provided", function()
			local runs = 0
			local def = Fakes.module("Ticker", {
				Start = function(self)
					self.Context.Scheduler:Every("tick", 1, function()
						runs += 1
					end)
				end,
			})
			local framework, fake = boot({}, { def }, { Heartbeat = true })
			framework:Start()
			fake.Clock.Advance(1)
			fake.Heartbeat:Fire()
			expect(runs).toBe(1)
			framework:Stop()
			expect(fake.Heartbeat:ConnectionCount()).toBe(0)
			fake.Clock.Advance(1)
			fake.Heartbeat:Fire()
			expect(runs).toBe(1)
		end)
	end)

	t.describe("Module context", function()
		t.it("auto-releases subscriptions and tasks made during Start when stopped", function()
			local events, ticks = 0, 0
			local def = Fakes.module("M", {
				Start = function(self)
					self.Context.Events:Subscribe(Topics.PlayerSessionStarted, function()
						events += 1
					end)
					self.Context.Scheduler:Every("tick", 1, function()
						ticks += 1
					end)
				end,
			})
			local framework, fake = boot({}, { def })
			framework:Start()
			framework:Stop()
			fake.Players:Join(Fakes.player(1))
			fake.Clock.Advance(5)
			framework:Step()
			expect(events).toBe(0)
			expect(ticks).toBe(0)
		end)

		t.it("re-establishes Start resources after a restart", function()
			local events = 0
			local def = Fakes.module("M", {
				Start = function(self)
					self.Context.Events:Subscribe(Topics.PlayerSessionStarted, function()
						events += 1
					end)
				end,
			})
			local framework, fake = boot({}, { def })
			framework:Start()
			framework:Stop()
			framework:Start()
			fake.Players:Join(Fakes.player(1))
			expect(events).toBe(1)
		end)

		t.it("namespaces module topics and forbids publishing core topics", function()
			local received = nil
			local def = Fakes.module("Speed", {
				Start = function(self)
					local topic = self.Context.Events:Declare("Sample")
					self.Context.Events:Subscribe(topic, function(p)
						received = p
					end)
					self.Context.Events:Publish(topic, 42)
				end,
			})
			local framework = boot({}, { def })
			framework:Start()
			expect(received).toBe(42)
			expect(function()
				def.Context.Events:Publish(Topics.DetectionReported, {})
			end).toThrow("may only publish its own topics")
		end)

		t.it("only exposes declared dependencies through GetModule", function()
			local base = Fakes.module("Base", { Answer = 42 })
			local user = Fakes.module("User", { Dependencies = { "Base" } })
			local framework = boot({}, { base, user, Fakes.module("Other") })
			framework:Start()
			expect(user.Context:GetModule("Base").Answer).toBe(42)
			expect(function()
				user.Context:GetModule("Other")
			end).toThrow("did not declare")
		end)

		t.it("gives each module a scoped logger", function()
			local def = Fakes.module("Speed", {
				Start = function(self)
					self.Context.Logger:Info("hello")
				end,
			})
			local framework, fake = boot({}, { def })
			framework:Start()
			local entry = Fakes.findLogs(fake.Logs, "hello")[1]
			expect(entry.Scope).toBe("Speed")
		end)
	end)

	t.describe("Player sessions", function()
		t.it("creates sessions for joining and pre-existing players", function()
			local fake = Fakes.environment()
			fake.Players:Preload(Fakes.player(1))
			local framework = Framework.new(fake.Env)
			framework:Initialize({})
			framework:Start()
			fake.Players:Join(Fakes.player(2))
			expect(#framework:GetSessions()).toBe(2)
		end)

		t.it("lets modules observe players who were present before Start", function()
			local fake = Fakes.environment()
			fake.Players:Preload(Fakes.player(7))
			local seen = {}
			local def = Fakes.module("Watcher", {
				Start = function(self)
					self.Context.Events:Subscribe(Topics.PlayerSessionStarted, function(p)
						table.insert(seen, p.Session.UserId)
					end)
				end,
			})
			local framework = Framework.new(fake.Env)
			framework:Initialize({})
			framework:RegisterModule(def)
			framework:Start()
			expect(seen).toEqual({ 7 })
		end)

		t.it("ends sessions on leave, runs session cleanup, and issues new ids on rejoin", function()
			local framework, fake = boot({})
			framework:Start()
			local player = fake.Players:Join(Fakes.player(1))
			local first = framework:GetSession(player)
			local cleaned = false
			first.Cleanup:Add(function()
				cleaned = true
			end)
			first:GetState("x", function()
				return { 1 }
			end)
			fake.Players:Leave(player)
			expect(framework:GetSession(player)).toBeNil()
			expect(first.Active).toBe(false)
			expect(cleaned).toBe(true)
			expect(first:GetState("x")).toBeNil()

			local again = fake.Players:Join(Fakes.player(1))
			local second = framework:GetSession(again)
			expect(second.SessionId ~= first.SessionId).toBe(true)
			expect(framework:GetSession(first)).toBeNil()
		end)

		t.it("tracks character spawns and generations", function()
			local framework, fake = boot({})
			local spawns = {}
			framework:Subscribe(Topics.CharacterSpawned, function(p)
				table.insert(spawns, p.Generation)
			end)
			framework:Start()
			local player = fake.Players:Join(Fakes.player(1))
			player:Spawn()
			player:Spawn()
			local session = framework:GetSession(player)
			expect(spawns).toEqual({ 1, 2 })
			expect(session.CharacterGeneration).toBe(2)
			player:Despawn()
			expect(session.Character).toBeNil()
		end)

		t.it("treats an already-spawned character as a spawn when the session starts", function()
			local fake = Fakes.environment()
			local player = Fakes.player(1)
			player:Spawn()
			fake.Players:Preload(player)
			local framework = Framework.new(fake.Env)
			framework:Initialize({})
			framework:Start()
			expect(framework:GetSession(player).CharacterGeneration).toBe(1)
		end)

		t.it("ignores duplicate PlayerAdded for the same player", function()
			local framework, fake = boot({})
			framework:Start()
			local player = fake.Players:Join(Fakes.player(1))
			local session = framework:GetSession(player)
			fake.Players.PlayerAdded:Fire(player)
			expect(framework:GetSession(player)).toBe(session)
			expect(framework:GetStatus().Players.Started).toBe(1)
		end)

		t.it("disconnects player connections when stopped", function()
			local framework, fake = boot({})
			framework:Start()
			local player = fake.Players:Join(Fakes.player(1))
			framework:Stop()
			expect(fake.Players.PlayerAdded:ConnectionCount()).toBe(0)
			expect(player.CharacterAdded:ConnectionCount()).toBe(0)
			expect(#framework:GetSessions()).toBe(0)
		end)
	end)

	t.describe("Detection pipeline", function()
		local function detector(overrides)
			return Fakes.module("Speed", overrides or { Category = "Movement" })
		end

		t.it("records a detection as evidence and publishes it", function()
			local def = detector()
			local framework, fake = boot({}, { def })
			local published = {}
			framework:OnDetection(function(p)
				table.insert(published, p)
			end)
			framework:Start()
			local player = fake.Players:Join(Fakes.player(1))
			local ok, id = def.Context:Report(player, {
				Kind = "SpeedExceeded",
				Severity = 20,
				Confidence = 0.7,
				Details = { Speed = 80, Limit = 16 },
			})
			expect(ok).toBe(true)
			expect(#published).toBe(1)
			local event = published[1].Event
			expect(event.Id).toBe(id)
			expect(event.Detector).toBe("Speed")
			expect(event.Category).toBe("Movement")
			expect(event.UserId).toBe(1)
			expect(event.Details.Speed).toBe(80)
			expect(table.isfrozen(event)).toBe(true)
			local evidence = framework:GetEvidence(player)
			expect(#evidence).toBe(1)
			expect(evidence[1].Kind).toBe("SpeedExceeded")
		end)

		t.it("accepts a UserId or Session as the target", function()
			local def = detector()
			local framework, fake = boot({}, { def })
			framework:Start()
			local player = fake.Players:Join(Fakes.player(5))
			expect((def.Context:Report(5, { Kind = "A", Severity = 1, Confidence = 1 }))).toBe(true)
			expect((def.Context:Report(framework:GetSession(player), { Kind = "B", Severity = 1, Confidence = 1 }))).toBe(true)
		end)

		t.it("rejects reports for unknown players", function()
			local def = detector()
			local framework = boot({}, { def })
			framework:Start()
			local ok, reason = def.Context:Report(Fakes.player(99), { Kind = "A", Severity = 1, Confidence = 1 })
			expect(ok).toBe(false)
			expect(reason).toBe("no_session")
		end)

		t.it("rejects reports from a module that is not running", function()
			local def = detector()
			local framework, fake = boot({}, { def })
			framework:Start()
			local player = fake.Players:Join(Fakes.player(1))
			framework:Stop()
			fake.Players:Join(player)
			local ok, reason = def.Context:Report(player, { Kind = "A", Severity = 1, Confidence = 1 })
			expect(ok).toBe(false)
			expect(reason).toBe("module_not_running")
		end)

		t.it("validates report input", function()
			local def = detector()
			local framework, fake = boot({}, { def })
			framework:Start()
			local player = fake.Players:Join(Fakes.player(1))
			local cases = {
				{ Kind = "", Severity = 1, Confidence = 1 },
				{ Kind = "A", Severity = 101, Confidence = 1 },
				{ Kind = "A", Severity = 1, Confidence = 1.5 },
				{ Kind = "A", Severity = 0 / 0, Confidence = 1 },
				{ Kind = "A", Severity = 1, Confidence = 1, Details = "text" },
				{ Kind = string.rep("x", 65), Severity = 1, Confidence = 1 },
			}
			for _, input in cases do
				local ok, reason = def.Context:Report(player, input)
				expect(ok).toBe(false)
				expect(reason).toContain("invalid_input")
			end
			expect(#framework:GetEvidence(player)).toBe(0)
		end)

		t.it("keeps evidence after the player leaves", function()
			local def = detector()
			local framework, fake = boot({}, { def })
			framework:Start()
			local player = fake.Players:Join(Fakes.player(1))
			def.Context:Report(player, { Kind = "A", Severity = 5, Confidence = 1 })
			fake.Players:Leave(player)
			expect(#framework:GetEvidence(1)).toBe(1)
		end)

		t.it("prunes expired evidence on the scheduler", function()
			local def = detector()
			local framework, fake = boot({ Evidence = { RetentionSeconds = 10, PruneIntervalSeconds = 5 } }, { def })
			framework:Start()
			local player = fake.Players:Join(Fakes.player(1))
			def.Context:Report(player, { Kind = "A", Severity = 5, Confidence = 1 })
			fake.Clock.Advance(15)
			framework:Step()
			expect(#framework:GetEvidence(1)).toBe(0)
		end)

		t.it("isolates a failing detection subscriber from the reporting module", function()
			local def = detector()
			local framework, fake = boot({}, { def })
			framework:OnDetection(function()
				error("subscriber bug")
			end)
			framework:Start()
			local player = fake.Players:Join(Fakes.player(1))
			local ok = def.Context:Report(player, { Kind = "A", Severity = 5, Confidence = 1 })
			expect(ok).toBe(true)
			expect(#framework:GetEvidence(player)).toBe(1)
		end)
	end)
end
