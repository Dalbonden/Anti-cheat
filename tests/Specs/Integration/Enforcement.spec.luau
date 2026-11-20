--[[
	Graduated enforcement in the full framework: restriction of tagged remotes and combat,
	movement correction, temporary restriction, automatic and approved kicks and bans,
	escalation, shadow mode, overrides, persistence and the audit log.

	Probe modules drive risk with chosen categories; real RemoteSecurity, Combat and
	Movement consult enforcement.
]]

local ACF = game:GetService("ServerScriptService").ACF
local Framework = require(ACF.Core.Framework)
local Fakes = require(script.Parent.Parent.Fakes)

local PROBES = {
	MoveProbe = "Movement",
	CombatProbe = "Combat",
	EcoProbe = "Economy",
	AimStat = "Behavioral",
}

local function world(config, envOptions)
	local fake = Fakes.environment(envOptions)
	fake.Physics:AddFloor()
	local framework = Framework.new(fake.Env)
	local probes = {}
	for name, category in PROBES do
		local probe = Fakes.module(name, { Category = category })
		framework:RegisterModule(probe)
		probes[name] = probe
	end
	local merged = config or {}
	merged.Risk = merged.Risk or {}
	merged.Risk.Groups = merged.Risk.Groups or { AimStat = "Aim" }
	framework:Initialize(merged)
	framework:GetModule("Combat"):Define("Rifle", { Kind = "Hitscan", Damage = 25, FireRate = 10, MaxRange = 300 })
	framework:Start()
	local w = { framework = framework, fake = fake, probes = probes, enforcer = fake.Enforcer }
	function w.join(id)
		local player = fake.Players:Join(Fakes.player(id or 1, "P" .. tostring(id or 1)))
		local character = player:Spawn()
		fake.Physics:Set(character, {})
		Fakes.instance("Tool", "Rifle", character)
		return player, character
	end
	function w.report(player, probe, severity, kind)
		probes[probe].Context:Report(player, { Kind = kind or (probe .. "Kind"), Severity = severity, Confidence = 1 })
	end
	function w.advance(seconds, step)
		local dt = step or 1
		local steps = math.max(1, math.ceil(seconds / dt))
		for _ = 1, steps do
			fake.Clock.Advance(seconds / steps)
			framework:Step()
		end
	end
	function w.audit(kind, userId)
		return framework:GetAuditLog({ Type = kind, UserId = userId })
	end
	function w.remote(name, restrict)
		local remote = Fakes.remoteEvent(name)
		local calls = { n = 0 }
		framework:GetModule("RemoteSecurity"):ProtectEvent(remote, {
			Arguments = {},
			Restrict = restrict,
			Handler = function()
				calls.n += 1
			end,
		})
		return remote, calls
	end
	function w.shoot(player)
		return framework:GetModule("Combat"):ValidateAttack(player, "Rifle", { Origin = Fakes.vector3(0, 4.5, 0) })
	end
	return w
end

return function(t)
	local expect = t.expect

	t.describe("Enforcement", function()
		t.it("normal players are at level 0 and nothing is restricted", function()
			local w = world()
			local p = w.join()
			local trade, calls = w.remote("Trade", "Economy")
			Fakes.fire(trade, p)
			expect(calls.n).toBe(1)
			expect(w.framework:GetEnforcement(p).Level).toBe(0)
			expect(w.shoot(p).Allowed).toBe(true)
		end)

		t.it("level 2 rejects only operations tagged with the player's risk groups", function()
			local w = world()
			local p = w.join()
			local trade, tradeCalls = w.remote("Trade", "Economy")
			local emote, emoteCalls = w.remote("Emote", nil)
			local sprint, sprintCalls = w.remote("Sprint", "Movement")
			w.report(p, "EcoProbe", 45) -- Economy 45: Restrict band, tag Economy
			local state = w.framework:GetEnforcement(p)
			expect(state.Level).toBe(2)
			expect(state.Tags).toEqual({ "Economy" })
			for _ = 1, 5 do
				Fakes.fire(trade, p)
			end
			Fakes.fire(emote, p)
			Fakes.fire(sprint, p)
			expect(tradeCalls.n).toBe(0)
			expect(emoteCalls.n).toBe(1)
			expect(sprintCalls.n).toBe(1)
			expect(w.framework:GetModule("RemoteSecurity"):GetStats().Trade.Rejected.restricted).toBe(5)
			-- An enforcement rejection is not player behaviour: no Remote evidence.
			for _, record in w.framework:GetEvidence(p) do
				expect(record.Category ~= "Remote").toBe(true)
			end
			-- Five rejections, one audit entry (summarised).
			expect(#w.audit("Rejected", 1)).toBe(1)
			expect(w.framework:IsRestricted(p, "Economy")).toBe(true)
			expect(w.shoot(p).Allowed).toBe(true) -- combat is not tagged
		end)

		t.it("Aim or Combat restriction refuses shots without scoring them", function()
			local w = world()
			local p = w.join()
			w.report(p, "AimStat", 45)
			local result = w.shoot(p)
			expect(result.Allowed).toBe(false)
			expect(result.Reason).toBe("Restricted")
			expect(result.ShotAccepted).toBe(false)
			expect(w.framework:GetModule("Combat"):GetStats().Rejected.Restricted).toBe(1)
		end)

		t.it("level 3 corrects a Movement-tagged player back to the last grounded position", function()
			local w = world()
			local p, character = w.join()
			for i = 1, 10 do
				w.fake.Physics:Set(character, { X = i * 2 })
				w.advance(0.2, 0.2)
			end
			w.report(p, "MoveProbe", 65) -- Investigation, tag Movement
			expect(w.framework:GetEnforcement(p).Level).toBe(3)
			local before = #w.fake.Physics.Corrections
			w.fake.Physics:Set(character, { X = 150 }) -- teleport
			w.advance(0.2, 0.2)
			local corrections = w.fake.Physics.Corrections
			expect(#corrections).toBe(before + 1)
			expect(corrections[#corrections].X).toBe(20)
			expect(#w.audit("Corrected", 1)).toBe(1)
			-- Cooldown: a second teleport inside 1 s is not corrected again.
			w.fake.Physics:Set(character, { X = 160 })
			w.advance(0.2, 0.2)
			expect(#w.fake.Physics.Corrections).toBe(before + 1)
		end)

		t.it("no correction without a Movement tag, or beyond MaxDistance", function()
			local w = world()
			local p, character = w.join()
			for i = 1, 5 do
				w.fake.Physics:Set(character, { X = i })
				w.advance(0.2, 0.2)
			end
			w.report(p, "CombatProbe", 65) -- Investigation, tag Combat only
			w.fake.Physics:Set(character, { X = 150 })
			w.advance(0.2, 0.2)
			expect(#w.fake.Physics.Corrections).toBe(0)

			local w2 = world()
			local p2, c2 = w2.join()
			w2.advance(0.4, 0.2)
			w2.report(p2, "MoveProbe", 65)
			w2.fake.Physics:Set(c2, { X = 900 })
			w2.advance(0.2, 0.2)
			expect(#w2.fake.Physics.Corrections).toBe(0)
		end)

		t.it("level 4 restricts every tag for TemporaryRestrictionSeconds", function()
			local w = world()
			local p = w.join()
			local emote, calls = w.remote("Emote", true)
			w.report(p, "AimStat", 85) -- EnforcementReview, statistical only: no kick
			local state = w.framework:GetEnforcement(p)
			expect(state.Level).toBe(4)
			expect(state.RestrictedFor).toBe(600)
			expect(w.framework:IsRestricted(p, "Movement")).toBe(true)
			Fakes.fire(emote, p)
			expect(calls.n).toBe(0)
			expect(#w.enforcer.Kicks).toBe(0)
		end)

		t.it("statistical evidence alone opens a case; staff approval kicks", function()
			local w = world()
			local p = w.join()
			w.report(p, "AimStat", 50)
			w.report(p, "EcoProbe", 40)
			local cases = w.framework:GetCases({ Status = "Open" })
			expect(#cases).toBe(1)
			expect(cases[1].ProposedLevel).toBe(5)
			expect(cases[1].Type).toBe("Action")
			expect(string.find(cases[1].Explanation, "Aim", 1, true) ~= nil).toBe(true)
			expect(#w.enforcer.Kicks).toBe(0)
			expect(function()
				w.framework:ApproveCase(cases[1].CaseId, {})
			end).toThrow("options.By")
			w.framework:ApproveCase(cases[1].CaseId, { By = "Mod_Alice", Note = "reviewed footage" })
			expect(#w.enforcer.Kicks).toBe(1)
			expect(string.find(w.enforcer.Kicks[1].Message, "ACF-", 1, true) ~= nil).toBe(true)
			local kicked = w.audit("Kicked", 1)[1]
			expect(kicked.By).toBe("Mod_Alice")
			expect(kicked.ApprovedBy).toBe("Mod_Alice")
			expect(w.framework:GetCases({ Status = "Approved" })[1].DecidedBy).toBe("Mod_Alice")
		end)

		t.it("rejecting a case takes no action and is audited", function()
			local w = world()
			local p = w.join()
			w.report(p, "AimStat", 85)
			local case = w.framework:GetCases({ Status = "Open" })[1]
			w.framework:RejectCase(case.CaseId, { By = "Mod_Bob", Note = "pro player, verified" })
			expect(#w.enforcer.Kicks).toBe(0)
			expect(w.audit("CaseRejected", 1)[1].By).toBe("Mod_Bob")
			expect(function()
				w.framework:ApproveCase(case.CaseId, { By = "Mod_Bob" })
			end).toThrow("is Rejected")
		end)

		t.it("the Investigation band opens a review case; staff can choose the action", function()
			local w = world()
			local p = w.join()
			w.report(p, "CombatProbe", 65)
			local case = w.framework:GetCases({ Status = "Open" })[1]
			expect(case.Type).toBe("Review")
			expect(case.ProposedLevel).toBeNil()
			expect(function()
				w.framework:ApproveCase(case.CaseId, { By = "Mod" })
			end).toThrow("needs a removal Level")
			w.framework:ApproveCase(case.CaseId, { By = "Mod", Level = 6, Hours = 2 })
			expect(w.enforcer.Bans[1].Seconds).toBe(7200)
			expect(#w.enforcer.Kicks).toBe(1)
		end)

		t.it("corroborated evidence kicks automatically, then waits for new evidence after rejoin", function()
			local w = world()
			local p = w.join()
			w.report(p, "MoveProbe", 50)
			w.report(p, "CombatProbe", 35)
			expect(#w.enforcer.Kicks).toBe(1)
			local kicked = w.audit("Kicked", 1)[1]
			expect(kicked.By).toBe("ACF (automatic)")
			expect(w.framework:GetEnforcement(1).History[1].Type).toBe("Kick")

			w.join(1) -- rejoins with the same (decaying) risk
			w.advance(5)
			expect(#w.enforcer.Kicks).toBe(1)
			expect(w.framework:GetEnforcement(1).Level).toBe(4) -- still restricted

			w.report(1, "MoveProbe", 50, "AnotherKind") -- cheats again
			expect(#w.enforcer.Kicks).toBe(2)
			w.join(1)
			w.advance(1)
			w.report(1, "CombatProbe", 50, "AnotherKind")
			-- Two recent kicks: the next step is a temporary ban, which needs approval (AutoBan off).
			expect(#w.enforcer.Kicks).toBe(2)
			local case = w.framework:GetCases({ Status = "Open" })[1]
			expect(case.ProposedLevel).toBe(6)
		end)

		t.it("AutoBan escalates to an automatic temporary ban; permanent still needs approval", function()
			local w = world({ Enforcement = { AutoBan = true, Bans = { KicksBeforeTempBan = 1, TempBansBeforePermanentProposal = 1 } } })
			local p = w.join()
			w.report(p, "MoveProbe", 50)
			w.report(p, "CombatProbe", 35)
			expect(#w.enforcer.Kicks).toBe(1)
			w.join(1)
			w.advance(1)
			w.report(1, "MoveProbe", 50, "K2")
			expect(#w.enforcer.Bans).toBe(1)
			expect(w.enforcer.Bans[1].Seconds).toBe(24 * 3600)
			w.advance(25 * 3600, 3600) -- ban over
			w.join(1)
			w.report(1, "MoveProbe", 60, "K3")
			w.report(1, "CombatProbe", 50, "K3")
			expect(#w.enforcer.Bans).toBe(1)
			local case = w.framework:GetCases({ Status = "Open" })[1]
			expect(case.ProposedLevel).toBe(7)
		end)

		t.it("shadow mode decides and audits everything but applies nothing", function()
			local w = world({ Enforcement = { ShadowMode = true } })
			local p = w.join()
			local trade, calls = w.remote("Trade", "Economy")
			w.report(p, "EcoProbe", 45)
			Fakes.fire(trade, p)
			expect(calls.n).toBe(1)
			expect(w.audit("Rejected", 1)[1].Shadow).toBe(true)
			w.report(p, "MoveProbe", 50)
			w.report(p, "CombatProbe", 35)
			expect(#w.enforcer.Kicks).toBe(0)
			expect(w.audit("ShadowAction", 1)[1].Level).toBe("Kick")
			expect(w.shoot(p).Allowed).toBe(true)
			-- Staff actions still work in shadow mode.
			w.framework:Kick(p, { By = "Mod", Reason = "manual" })
			expect(#w.enforcer.Kicks).toBe(1)
		end)

		t.it("shadow cases cannot be approved", function()
			local w = world({ Enforcement = { ShadowMode = true } })
			local p = w.join()
			w.report(p, "AimStat", 85)
			local case = w.framework:GetCases({ Status = "Shadow" })[1]
			expect(case ~= nil).toBe(true)
			expect(function()
				w.framework:ApproveCase(case.CaseId, { By = "Mod" })
			end).toThrow("is Shadow")
		end)

		t.it("Mode Off only logs; Manual never removes automatically", function()
			local off = world({ Enforcement = { Mode = "Off" } })
			local p = off.join()
			off.report(p, "MoveProbe", 50)
			off.report(p, "CombatProbe", 50)
			expect(off.framework:GetEnforcement(p).Level).toBe(0)
			expect(#off.enforcer.Kicks).toBe(0)

			local manual = world({ Enforcement = { Mode = "Manual" } })
			local q = manual.join()
			manual.report(q, "MoveProbe", 50)
			manual.report(q, "CombatProbe", 50)
			expect(#manual.enforcer.Kicks).toBe(0)
			expect(manual.framework:GetEnforcement(q).Level).toBe(4)
			expect(manual.framework:GetCases({ Status = "Open" })[1].ProposedLevel).toBe(5)
		end)

		t.it("temporary bans are enforced on join and expire", function()
			local w = world()
			local p = w.join()
			local appeal = w.framework:Ban(p, { By = "Admin", Reason = "exploit", Hours = 2 })
			expect(#w.enforcer.Kicks).toBe(1)
			expect(w.enforcer.Bans[1].Seconds).toBe(7200)
			expect(string.find(w.enforcer.Kicks[1].Message, appeal, 1, true) ~= nil).toBe(true)
			w.join(1)
			expect(#w.enforcer.Kicks).toBe(2)
			expect(w.audit("BanEnforced", 1)[1].AppealRef).toBe(appeal)
			w.advance(7300, 100)
			w.join(1)
			expect(#w.enforcer.Kicks).toBe(2)
			expect(#w.audit("BanExpired", 1)).toBe(1)
			local history = w.framework:GetEnforcement(1).History
			expect(history[#history].Type).toBe("Expired")
		end)

		t.it("bans persist across servers through the Store, and unbans lift them", function()
			local store = Fakes.store()
			local first = world(nil, { Store = store })
			first.framework:Ban(42, { By = "Admin", Reason = "offline ban" }) -- player not in this server
			expect(#first.enforcer.Kicks).toBe(0)
			expect(store.Data.ACF_Bans_v1.Bans_42.Active.Level).toBe(7)

			local second = world(nil, { Store = store })
			second.join(42)
			expect(#second.enforcer.Kicks).toBe(1)
			second.framework:Unban(42, { By = "Admin", Reason = "appeal upheld" })
			expect(second.enforcer.Unbans[1]).toBe(42)
			second.join(42)
			expect(#second.enforcer.Kicks).toBe(1)
			local record = store.Data.ACF_Bans_v1.Bans_42
			expect(record.Active).toBeNil()
			expect(record.History[#record.History].Type).toBe("Unban")
		end)

		t.it("a ban takes effect immediately even when the record store is failing", function()
			local store = Fakes.store()
			store.FailLoads = 100
			local w = world(nil, { Store = store })
			local p = w.join()
			w.framework:Ban(p, { By = "Admin", Reason = "x", Hours = 1 })
			expect(#w.enforcer.Kicks).toBe(1)
			expect(#w.enforcer.Bans).toBe(1)
			for _ = 1, 6 do
				w.advance(5)
			end
			expect(#w.audit("PersistenceFailed", 1) >= 1).toBe(true)
		end)

		t.it("a failed Roblox ban API call is logged; ACF's record still enforces the ban", function()
			local w = world()
			w.enforcer.FailBans = 1
			local p = w.join()
			w.framework:Ban(p, { By = "Admin", Hours = 5 })
			expect(#Fakes.findLogs(w.fake.Logs, "Roblox ban API call failed", "Error")).toBe(1)
			w.join(1)
			expect(#w.enforcer.Kicks).toBe(2)
		end)

		t.it("overrides: exempt players are never restricted or removed; level overrides expire", function()
			local w = world()
			local p = w.join()
			w.framework:SetEnforcementOverride(p, { Exempt = true, By = "Admin", Reason = "developer testing" })
			w.report(p, "MoveProbe", 50)
			w.report(p, "CombatProbe", 50)
			expect(#w.enforcer.Kicks).toBe(0)
			expect(w.framework:IsRestricted(p, "Movement")).toBe(false)
			expect(w.framework:GetEnforcement(p).Level).toBe(0)
			w.framework:ClearEnforcementOverride(p, { By = "Admin" })

			local q = w.join(2)
			w.framework:SetEnforcementOverride(q, { Level = 2, Seconds = 60, By = "Mod", Reason = "watch" })
			expect(w.framework:GetEnforcement(q).Level).toBe(2)
			expect(function()
				w.framework:SetEnforcementOverride(q, { Level = 5, By = "Mod" })
			end).toThrow("use Kick/Ban")
			w.advance(61)
			expect(w.framework:GetEnforcement(q).Override).toBeNil()
			expect(#w.audit("OverrideCleared", 2)).toBe(1)
		end)

		t.it("every staff action needs By; the audit log is bounded and published", function()
			local w = world({ Enforcement = { Audit = { MaxEntries = 10 } } })
			local p = w.join()
			expect(function()
				w.framework:Kick(p, {})
			end).toThrow("options.By")
			expect(function()
				w.framework:Ban(p, { By = "x", Hours = -1 })
			end).toThrow("positive number")
			local published = 0
			w.framework:Subscribe("ACF.EnforcementAudit", function()
				published += 1
			end)
			for i = 1, 15 do
				w.framework:SetEnforcementOverride(p, { Level = i % 3, By = "Mod" })
			end
			expect(#w.framework:GetAuditLog() <= 10).toBe(true)
			expect(published >= 15).toBe(true)
		end)

		t.it("pending enforcement writes are flushed at shutdown", function()
			local store = Fakes.store()
			local w = world(nil, { Store = store })
			store.Deferred = true
			w.framework:Ban(7, { By = "Admin" })
			expect(w.fake.Shutdown.Pending() >= 1).toBe(true)
			for _ = 1, 3 do
				store.Complete()
				w.fake.Shutdown.Flush()
			end
			store.Complete()
			expect(w.fake.Shutdown.Pending()).toBe(0)
			expect(store.Data.ACF_Bans_v1.Bans_7.Active.Level).toBe(7)
		end)
	end)
end
