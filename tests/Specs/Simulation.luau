--[[
	Population simulator for Phase 8: honest players and cheaters running together
	through the full framework (detection, risk, enforcement) with fakes. Deterministic
	(seeded Park-Miller RNG), so a run is reproducible in Lune and in Studio.

	Used by Integration/Population.spec (a short run in the normal suite) and by
	tests/lune/evaluate.luau (long runs that measure accuracy, false positives, CPU and
	memory; see docs/EVALUATION.md).

	World: floor at y = 0. Honest players stay in |x|, |z| <= 120. A wall stands at
	x = 150..152, z = -60..60, y = 0..20, used only by the noclip cheater. Server samples
	every 0.2 s.

	Honest behaviour, randomised per player:
	  - walking below WalkSpeed with direction changes, idling, jumping;
	  - sprinting granted by the server (WalkSpeed 24);
	  - lag spikes (0.6-3 s freezes, then a catch-up);
	  - jittery delivery at high ping;
	  - respawns, and server teleports with AuthorizeTeleport;
	  - shooting at other players with a personal accuracy / headshot rate;
	  - earning coins steadily, in lumps, in bursts, or with a 2x gamepass;
	  - clicking in human rhythm (CV 8-30 %), at 60 Hz frame times;
	  - a protected shop remote, with the odd purchase they can't afford.

	Cheats (start at StartAt, honest before):
	  Speed (2.5x), Teleport (80 studs every 3 s), Fly (hover at y 40), Noclip (walks through
	  the wall), Aimbot (99 % hits, 90 % heads), RapidFire (15 shots/s on a 10/s rifle),
	  Duper (10x coins), AutoClicker (1 s period, 3 ms jitter), RemoteSpam (invalid args).
]]

local ACF = game:GetService("ServerScriptService").ACF
local Framework = require(ACF.Core.Framework)
local Validators = require(ACF.Detection.RemoteSecurity.Validators)
local Fakes = require(script.Parent.Fakes)

local DT = 0.2
local GRAVITY = 196.2
local STAND = 3
local BOUNDS = 120

local Simulation = {}

Simulation.CHEATS = table.freeze({
	"Speed",
	"Teleport",
	"Fly",
	"Noclip",
	"Aimbot",
	"RapidFire",
	"Duper",
	"AutoClicker",
	"RemoteSpam",
})

-- Evidence categories that count as catching each cheat.
Simulation.EXPECTED = table.freeze({
	Speed = { Movement = true, Physics = true },
	Teleport = { Movement = true, Physics = true },
	Fly = { Movement = true },
	Noclip = { Movement = true },
	Aimbot = { Behavioral = true },
	RapidFire = { Combat = true },
	Duper = { Behavioral = true },
	AutoClicker = { Behavioral = true },
	RemoteSpam = { Remote = true },
})

local BAND_INDEX = { Normal = 1, Increased = 2, Restrict = 3, Investigation = 4, EnforcementReview = 5 }

local function rng(seed: number)
	local state = seed % 2147483647
	if state <= 0 then
		state += 2147483646
	end
	local r = {}
	function r.u(): number
		state = (state * 16807) % 2147483647
		return (state - 1) / 2147483646
	end
	function r.range(a: number, b: number): number
		return a + (b - a) * r.u()
	end
	function r.normal(mean: number, std: number): number
		local sum = 0
		for _ = 1, 12 do
			sum += r.u()
		end
		return mean + (sum - 6) * std
	end
	function r.chance(p: number): boolean
		return r.u() < p
	end
	return r
end

local function frame(t: number): number
	return math.ceil(t * 60 - 1e-9) / 60
end

function Simulation.new(options)
	local opts = options or {}
	local seed = opts.Seed or 1
	local r = rng(seed)
	local fake = Fakes.environment({ Store = opts.Store })
	fake.Physics:AddFloor()
	fake.Physics:AddBox(150, 0, -60, 152, 20, 60)
	local framework = Framework.new(fake.Env)
	for _, module in opts.Modules or {} do
		framework:RegisterModule(module)
	end
	local config = opts.Config or {}
	framework:Initialize(config)
	local combat = framework:GetModule("Combat")
	combat:Define("Rifle", { Kind = "Hitscan", Damage = 20, HeadshotMultiplier = 2, FireRate = 10, MaxRange = 300 })
	local behavioral = framework:GetModule("Behavioral")
	behavioral:DefineSignal("Coins")
	framework:Start()
	local movement = framework:GetModule("Movement")
	local buy = Fakes.remoteEvent("Buy")
	framework:GetModule("RemoteSecurity"):ProtectEvent(buy, {
		Arguments = { Validators.string({ MaxLength = 32 }), Validators.integer({ Min = 1, Max = 99 }) },
		RateLimit = { Burst = 5, PerSecond = 2 },
		Restrict = "Economy",
		Handler = function() end,
	})

	local sim = {
		framework = framework,
		fake = fake,
		agents = {},
		now = 0,
		acfSeconds = 0,
		stepSeconds = 0,
		steps = 0,
		events = {},
		nextId = 1,
		-- Per-player base ping is drawn from [pingMin, pingMax] seconds.
		pingMin = if opts.Ping then opts.Ping[1] else 0.03,
		pingMax = if opts.Ping then opts.Ping[2] else 0.45,
	}

	local function timed(fn, ...)
		local started = os.clock()
		local a, b = fn(...)
		sim.acfSeconds += os.clock() - started
		return a, b
	end

	local function schedule(at: number, fn)
		table.insert(sim.events, { at = at, fn = fn })
	end

	local function placeTargets(agent)
		fake.Physics:SetTarget(agent.torso, { X = agent.sx, Y = agent.sy, Z = agent.sz, Model = agent.character, Player = agent.player })
		fake.Physics:SetTarget(agent.head, { X = agent.sx, Y = agent.sy + 1.5, Z = agent.sz, Model = agent.character, Player = agent.player, IsHead = true })
	end

	local function spawn(agent, x: number, z: number)
		agent.character = agent.player:Spawn()
		agent.torso = Fakes.instance("Part", "UpperTorso", agent.character)
		agent.head = Fakes.instance("Part", "Head", agent.character)
		Fakes.instance("Tool", "Rifle", agent.character)
		agent.x, agent.y, agent.z, agent.vy = x, STAND, z, 0
		agent.sx, agent.sy, agent.sz = x, STAND, z
		fake.Physics:Set(agent.character, {
			X = x, Y = STAND, Z = z, VX = 0, VY = 0, VZ = 0,
			WalkSpeed = agent.walkSpeed, State = "Running", Ping = agent.ping,
		})
		placeTargets(agent)
	end

	-- Adds a player. role = "Honest" or one of Simulation.CHEATS.
	function sim.add(role: string, startAt: number?)
		local id = sim.nextId
		sim.nextId += 1
		local agent = {
			id = id,
			role = role,
			startAt = startAt or 60,
			player = fake.Players:Join(Fakes.player(id, `{role}{id}`)),
			walkSpeed = if r.chance(0.25) then 24 else 16,
			ping = r.range(sim.pingMin, sim.pingMax),
			skill = r.range(0.2, 0.7),
			headRate = r.range(0.1, 0.4),
			earn = ({ "steady", "lumpy", "bursty", "gamepass", "none" })[1 + math.floor(r.u() * 5)],
			clicker = r.chance(0.4),
			clickMean = r.range(0.3, 1.5),
			clickCv = r.range(0.08, 0.3),
			heading = r.range(0, 2 * math.pi),
			speed = 0,
			nextDecision = 0,
			freeze = 0,
			firstEvidence = nil,
			firstRestrict = nil,
			maxBand = "Normal",
			kicked = false,
		}
		spawn(agent, r.range(-100, 100), r.range(-100, 100))
		if role == "Noclip" then
			spawn(agent, 125, r.range(-40, 40))
		end
		table.insert(sim.agents, agent)
		if agent.clicker or role == "AutoClicker" then
			sim.scheduleClicks(agent, r.range(1, 10))
		end
		return agent
	end

	local function cheating(agent): boolean
		return agent.role ~= "Honest" and sim.now >= agent.startAt
	end

	-- Clicks are events at exact (60 Hz frame) times, not tick-aligned.
	function sim.scheduleClicks(agent, at: number)
		schedule(at, function()
			if agent.kicked then
				return
			end
			timed(behavioral.RecordAction, behavioral, agent.player, "Click")
			local nextAt
			if agent.role == "AutoClicker" and cheating(agent) then
				nextAt = frame(at + 1 + r.normal(0, 0.003))
			elseif r.chance(0.03) then
				nextAt = frame(at + r.range(5, 30)) -- pause between bursts
			else
				nextAt = frame(at + math.max(0.08, r.normal(agent.clickMean, agent.clickMean * agent.clickCv)))
			end
			sim.scheduleClicks(agent, math.max(nextAt, at + 1 / 60))
		end)
	end

	local function nearestTarget(agent)
		local best, bestDistance = nil, math.huge
		for _, other in sim.agents do
			if other ~= agent and not other.kicked and math.abs(other.sx) <= BOUNDS + 5 and math.abs(other.sz) <= BOUNDS + 5 then
				local d = math.sqrt((other.sx - agent.sx) ^ 2 + (other.sz - agent.sz) ^ 2)
				if d < bestDistance and d < 250 then
					best, bestDistance = other, d
				end
			end
		end
		return best
	end

	local function shoot(agent, hitChance: number, headChance: number)
		local origin = Fakes.vector3(agent.sx, agent.sy + 1.5, agent.sz)
		local claim = { Origin = origin }
		local target = nearestTarget(agent)
		if target and r.chance(hitChance) then
			if r.chance(headChance) then
				claim.Target = target.head
				claim.HitPosition = Fakes.vector3(target.sx, target.sy + 1.5, target.sz)
			else
				claim.Target = target.torso
				claim.HitPosition = Fakes.vector3(target.sx, target.sy, target.sz)
			end
		end
		timed(combat.ValidateAttack, combat, agent.player, "Rifle", claim)
	end

	local function move(agent)
		local cheat = cheating(agent) and agent.role or nil
		if agent.role == "Noclip" then
			-- Paces along x in front of the wall (x 150..152); once cheating, through it.
			local far = if cheat then 166 else 146
			agent.heading = if agent.x >= far then math.pi elseif agent.x <= 120 then 0 else agent.heading
			if agent.heading ~= 0 and agent.heading ~= math.pi then
				agent.heading = 0
			end
			agent.speed = 14
		elseif sim.now >= agent.nextDecision then
			agent.nextDecision = sim.now + r.range(1, 4)
			agent.heading = r.range(0, 2 * math.pi)
			agent.speed = if r.chance(0.2) then 0 else agent.walkSpeed * r.range(0.6, 0.95)
		end
		if agent.role ~= "Noclip" and (math.abs(agent.x) > BOUNDS or math.abs(agent.z) > BOUNDS) then
			agent.heading = math.atan2(-agent.z, -agent.x)
		end
		local speed = agent.speed
		if cheat == "Speed" then
			speed = agent.walkSpeed * 2.5
		end
		local vx, vz = math.cos(agent.heading) * speed, math.sin(agent.heading) * speed
		agent.x += vx * DT
		agent.z += vz * DT

		if cheat == "Teleport" and math.floor(sim.now / DT) % 15 == 0 then
			local angle = math.atan2(-agent.z, -agent.x) + r.range(-0.5, 0.5)
			agent.x += math.cos(angle) * 80
			agent.z += math.sin(angle) * 80
		end

		if cheat == "Fly" then
			agent.y, agent.vy = 40, 0
		else
			if agent.y <= STAND + 1e-6 and r.chance(0.03) then
				agent.vy = 50
			end
			agent.y += agent.vy * DT - 0.5 * GRAVITY * DT * DT
			agent.vy -= GRAVITY * DT
			if agent.y <= STAND then
				agent.y, agent.vy = STAND, 0
			end
		end

		-- Network effects (honest and cheaters alike).
		if agent.freeze > 0 then
			agent.freeze -= 1
			return
		end
		if r.chance(0.002) then
			agent.freeze = math.floor(r.range(3, 15))
			return
		end
		if agent.ping >= 0.25 and r.chance(0.25) then
			return
		end
		local airborne = agent.y > STAND + 0.01
		agent.sx, agent.sy, agent.sz = agent.x, agent.y, agent.z
		fake.Physics:Set(agent.character, {
			X = agent.x, Y = agent.y, Z = agent.z,
			VX = vx, VY = agent.vy, VZ = vz,
			State = if airborne then (if agent.vy > 0 then "Jumping" else "Freefall") else "Running",
			Ping = math.max(0.02, agent.ping + r.normal(0, 0.03)),
		})
		placeTargets(agent)
	end

	local function act(agent)
		local cheat = cheating(agent) and agent.role or nil
		-- Server events: respawn, authorised teleport.
		if r.chance(0.0005) then
			if agent.role == "Noclip" then
				-- Respawn in front of the wall (z within its extent), or it has nothing to pass through.
				spawn(agent, 140, r.range(-40, 40))
			else
				spawn(agent, r.range(-100, 100), r.range(-100, 100))
			end
			return
		end
		if r.chance(0.0005) and agent.role ~= "Noclip" then
			timed(movement.AuthorizeTeleport, movement, agent.player)
			agent.x, agent.z = r.range(-100, 100), r.range(-100, 100)
		end

		-- Combat.
		if cheat == "Aimbot" then
			if r.chance(0.4) then
				shoot(agent, 0.99, 0.9)
			end
		elseif cheat == "RapidFire" then
			for _ = 1, 3 do
				shoot(agent, 1, 0.2)
			end
		elseif r.chance(0.3) then
			shoot(agent, agent.skill, agent.headRate)
		end

		-- Economy.
		local amount = 0
		if cheat == "Duper" then
			amount = 50 * DT
		elseif agent.earn == "steady" then
			amount = math.max(0, r.normal(5, 1.5)) * DT
		elseif agent.earn == "gamepass" then
			amount = math.max(0, r.normal(10, 3)) * DT
		elseif agent.earn == "lumpy" then
			amount = if math.floor(sim.now / DT) % 100 == agent.id % 100 then 100 else 0
		elseif agent.earn == "bursty" then
			amount = if r.chance(0.3) then math.max(0, r.normal(16, 5)) * DT else 0
		end
		if amount > 0 then
			timed(behavioral.RecordSignal, behavioral, agent.player, "Coins", amount)
		end

		-- Shop remote.
		if cheat == "RemoteSpam" then
			for _ = 1, 5 do
				timed(Fakes.fire, buy, agent.player, string.rep("x", 100), -1)
			end
		elseif r.chance(0.04) then
			timed(Fakes.fire, buy, agent.player, "Sword", 1)
			timed(behavioral.RecordAction, behavioral, agent.player, "Buy", not r.chance(0.05))
		end
	end

	local function observe(agent)
		if agent.firstEvidence == nil then
			local expected = Simulation.EXPECTED[agent.role]
			for _, record in framework:GetEvidence(agent.player) do
				if expected == nil or expected[record.Category] then
					agent.firstEvidence = sim.now
					agent.firstKind = record.Kind
					break
				end
			end
		end
		local risk = framework:GetRisk(agent.player)
		if BAND_INDEX[risk.Band] > BAND_INDEX[agent.maxBand] then
			agent.maxBand = risk.Band
		end
		if agent.firstRestrict == nil and BAND_INDEX[risk.Band] >= BAND_INDEX.Restrict then
			agent.firstRestrict = sim.now
		end
	end

	-- Advances the world by `seconds`.
	function sim.run(seconds: number)
		local finish = sim.now + seconds
		while sim.now < finish - 1e-9 do
			local tickEnd = sim.now + DT
			table.sort(sim.events, function(a, b)
				return a.at < b.at
			end)
			while #sim.events > 0 and sim.events[1].at < tickEnd do
				local event = table.remove(sim.events, 1)
				if event.at > sim.now then
					fake.Clock.Advance(event.at - sim.now)
					sim.now = event.at
				end
				event.fn()
			end
			fake.Clock.Advance(tickEnd - sim.now)
			sim.now = tickEnd
			for _, agent in sim.agents do
				if not agent.kicked then
					move(agent)
					act(agent)
				end
			end
			local started = os.clock()
			framework:Step()
			local elapsed = os.clock() - started
			sim.stepSeconds += elapsed
			sim.acfSeconds += elapsed
			sim.steps += 1
			if sim.steps % 5 == 0 then
				for _, agent in sim.agents do
					if not agent.kicked then
						observe(agent)
					end
				end
			end
			for _, agent in sim.agents do
				if not agent.kicked and fake.Players:GetPlayers() and not table.find(fake.Players:GetPlayers(), agent.player) then
					agent.kicked = true
					agent.kickedAt = sim.now
				end
			end
		end
	end

	-- Honest players with any evidence / any enforcement, plus totals.
	function sim.honestReport()
		local report = { Players = 0, WithEvidence = 0, Records = 0, Kinds = {}, MaxBand = "Normal", Kicked = 0, Restricted = 0 }
		for _, agent in sim.agents do
			if agent.role == "Honest" then
				report.Players += 1
				local records = framework:GetEvidence(agent.player)
				if #records > 0 then
					report.WithEvidence += 1
				end
				for _, record in records do
					report.Records += 1
					report.Kinds[record.Kind] = (report.Kinds[record.Kind] or 0) + record.Count
				end
				if BAND_INDEX[agent.maxBand] > BAND_INDEX[report.MaxBand] then
					report.MaxBand = agent.maxBand
				end
				if agent.kicked then
					report.Kicked += 1
				end
				if BAND_INDEX[agent.maxBand] >= BAND_INDEX.Restrict then
					report.Restricted += 1
				end
			end
		end
		return report
	end

	return sim
end

return Simulation
