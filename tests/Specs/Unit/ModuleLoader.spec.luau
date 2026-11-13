local ACF = game:GetService("ServerScriptService").ACF
local EventBus = require(ACF.Core.EventBus)
local Logger = require(ACF.Core.Logger)
local ModuleLoader = require(ACF.Core.ModuleLoader)
local Topics = require(ACF.Core.Topics)
local Fakes = require(script.Parent.Parent.Fakes)

local function setup()
	local clock = Fakes.clock()
	local entries = {}
	local logger = Logger.new({
		Level = "Debug",
		Now = clock.Now,
		RateLimitBurst = 1000,
		Sink = function(e)
			table.insert(entries, e)
		end,
	})
	local bus = EventBus.new({ Logger = logger })
	for _, topic in Topics do
		bus:RegisterTopic(topic)
	end
	local transitions = {}
	bus:Subscribe(Topics.ModuleStateChanged, function(p)
		table.insert(transitions, `{p.Name}:{p.From}->{p.To}`)
	end)
	local loader = ModuleLoader.new({
		Logger = logger,
		Bus = bus,
		MakeContext = function(entry)
			return { Name = entry.Name }
		end,
	})
	return loader, transitions, entries
end

local function enabled()
	return true
end

return function(t)
	local expect = t.expect

	t.describe("ModuleLoader validation", function()
		t.it("accepts a complete definition", function()
			expect(ModuleLoader.Validate(Fakes.module("Speed"))).toBeNil()
		end)

		t.it("requires all four lifecycle methods", function()
			local def = Fakes.module("Speed")
			def.Destroy = nil
			expect(ModuleLoader.Validate(def)).toContain("Destroy")
		end)

		t.it("rejects bad names, categories, and dependency lists", function()
			expect(ModuleLoader.Validate(Fakes.module("1bad"))).toContain("identifier")
			expect(ModuleLoader.Validate(Fakes.module("A", { Category = "Cheats" }))).toContain("Category")
			expect(ModuleLoader.Validate(Fakes.module("A", { Dependencies = { "A" } }))).toContain("itself")
			expect(ModuleLoader.Validate(Fakes.module("A", { Dependencies = { "B", "B" } }))).toContain("twice")
			expect(ModuleLoader.Validate(Fakes.module("A", { ConfigSchema = {} }))).toContain("Schema.Table")
			expect(ModuleLoader.Validate("nope")).toContain("table")
		end)

		t.it("rejects duplicate registration", function()
			local loader = setup()
			loader:Register(Fakes.module("A"))
			expect(function()
				loader:Register(Fakes.module("A"))
			end).toThrow("already registered")
		end)
	end)

	t.describe("ModuleLoader lifecycle", function()
		t.it("initializes and starts in dependency order, stops and destroys in reverse", function()
			local loader = setup()
			local log = {}
			local function tracked(name, deps)
				return Fakes.module(name, {
					Dependencies = deps,
					Initialize = function()
						table.insert(log, "init " .. name)
					end,
					Start = function()
						table.insert(log, "start " .. name)
					end,
					Stop = function()
						table.insert(log, "stop " .. name)
					end,
					Destroy = function()
						table.insert(log, "destroy " .. name)
					end,
				})
			end
			loader:Register(tracked("C", { "B" }))
			loader:Register(tracked("A", nil))
			loader:Register(tracked("B", { "A" }))
			loader:Resolve(enabled)
			expect(loader:GetOrder()).toEqual({ "A", "B", "C" })
			loader:InitializeAll()
			loader:StartAll()
			loader:DestroyAll()
			expect(log).toEqual({
				"init A", "init B", "init C",
				"start A", "start B", "start C",
				"stop C", "stop B", "stop A",
				"destroy C", "destroy B", "destroy A",
			})
		end)

		t.it("publishes every state transition", function()
			local loader, transitions = setup()
			loader:Register(Fakes.module("A"))
			loader:Resolve(enabled)
			loader:InitializeAll()
			loader:StartAll()
			loader:StopAll()
			expect(transitions).toEqual({
				"A:Registered->Initializing",
				"A:Initializing->Initialized",
				"A:Initialized->Starting",
				"A:Starting->Running",
				"A:Running->Stopping",
				"A:Stopping->Stopped",
			})
		end)

		t.it("marks a throwing module Failed and blocks its dependents only", function()
			local loader, _, entries = setup()
			loader:Register(Fakes.module("Broken", {
				Initialize = function()
					error("cannot init")
				end,
			}))
			loader:Register(Fakes.module("Dependent", { Dependencies = { "Broken" } }))
			loader:Register(Fakes.module("Independent"))
			loader:Resolve(enabled)
			loader:InitializeAll()
			loader:StartAll()
			local states = loader:GetStates()
			expect(states.Broken.State).toBe("Failed")
			expect(states.Broken.Error).toContain("cannot init")
			expect(states.Dependent.State).toBe("Blocked")
			expect(states.Independent.State).toBe("Running")
			expect(#Fakes.findLogs(entries, "Module failed to initialize", "Error")).toBe(1)
		end)

		t.it("blocks modules with missing or disabled dependencies", function()
			local loader = setup()
			loader:Register(Fakes.module("NeedsGhost", { Dependencies = { "Ghost" } }))
			loader:Register(Fakes.module("Off"))
			loader:Register(Fakes.module("NeedsOff", { Dependencies = { "Off" } }))
			loader:Register(Fakes.module("Chain", { Dependencies = { "NeedsOff" } }))
			loader:Resolve(function(entry)
				return entry.Name ~= "Off"
			end)
			local states = loader:GetStates()
			expect(states.NeedsGhost.State).toBe("Blocked")
			expect(states.NeedsGhost.Error).toContain("missing dependency 'Ghost'")
			expect(states.Off.State).toBe("Disabled")
			expect(states.NeedsOff.Error).toContain("disabled")
			expect(states.Chain.State).toBe("Blocked")
		end)

		t.it("detects dependency cycles", function()
			local loader = setup()
			loader:Register(Fakes.module("A", { Dependencies = { "B" } }))
			loader:Register(Fakes.module("B", { Dependencies = { "A" } }))
			loader:Register(Fakes.module("Free"))
			loader:Resolve(enabled)
			local states = loader:GetStates()
			expect(states.A.State).toBe("Failed")
			expect(states.A.Error).toContain("cycle")
			expect(states.Free.State).toBe("Registered")
		end)

		t.it("releases Start resources at Stop and Initialize resources at Destroy", function()
			local loader = setup()
			local released = {}
			local entry
			loader:Register(Fakes.module("A", {
				Initialize = function()
					entry.ActiveCleanup:Add(function()
						table.insert(released, "init-resource")
					end)
				end,
				Start = function()
					entry.ActiveCleanup:Add(function()
						table.insert(released, "start-resource")
					end)
				end,
			}))
			entry = loader:Get("A")
			loader:Resolve(enabled)
			loader:InitializeAll()
			loader:StartAll()
			loader:StopAll()
			expect(released).toEqual({ "start-resource" })
			loader:DestroyAll()
			expect(released).toEqual({ "start-resource", "init-resource" })
		end)

		t.it("can restart stopped modules", function()
			local loader = setup()
			local def = Fakes.module("A")
			loader:Register(def)
			loader:Resolve(enabled)
			loader:InitializeAll()
			loader:StartAll()
			loader:StopAll()
			loader:StartAll()
			expect(loader:GetStates().A.State).toBe("Running")
			expect(def.Calls).toEqual({ "Initialize", "Start", "Stop", "Start" })
		end)

		t.it("still destroys a module whose Start failed", function()
			local loader = setup()
			local def = Fakes.module("A", {
				Start = function()
					error("nope")
				end,
			})
			local destroyed = false
			def.Destroy = function()
				destroyed = true
			end
			loader:Register(def)
			loader:Resolve(enabled)
			loader:InitializeAll()
			loader:StartAll()
			loader:DestroyAll()
			expect(destroyed).toBe(true)
			expect(loader:GetStates().A.State).toBe("Destroyed")
		end)

		t.it("refuses registration after resolve", function()
			local loader = setup()
			loader:Resolve(enabled)
			expect(function()
				loader:Register(Fakes.module("Late"))
			end).toThrow("after modules have been resolved")
		end)
	end)
end
