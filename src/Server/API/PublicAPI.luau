--!strict
--[[
	ACF public API: the process-wide singleton most games use.

		local ACF = require(game:GetService("ServerScriptService").ACF)
		ACF:Initialize({ LogLevel = "Info", Modules = { MyDetector = true } })
		ACF:RegisterModule(MyDetector.new())
		ACF:Start()

	Every method is documented in docs/API.md. For multiple isolated instances (tests,
	tools), use ACF.Framework.new(environment) directly.
]]

local Configuration = require(script.Parent.Parent.Core.Configuration)
local Framework = require(script.Parent.Parent.Core.Framework)
local Topics = require(script.Parent.Parent.Core.Topics)
local Combat = require(script.Parent.Parent.Detection.Combat.Combat)
local DetectionManager = require(script.Parent.Parent.Detection.DetectionManager)
local IntegrationAPI = require(script.Parent.IntegrationAPI)
local Policies = require(script.Parent.Parent.Detection.RemoteSecurity.Policies)
local Validators = require(script.Parent.Parent.Detection.RemoteSecurity.Validators)
local RobloxEnvironment = require(script.Parent.Parent.Platform.RobloxEnvironment)

local instance: Framework.Framework? = nil

local function framework(): Framework.Framework
	local current = instance
	if current then
		return current
	end
	local created = Framework.new(RobloxEnvironment.create())
	instance = created
	return created
end

local ACF = {}

ACF.Version = Framework.Version
ACF.Schema = Configuration.Schema
ACF.Topics = Topics
ACF.RejectReasons = DetectionManager.Reasons
ACF.Validators = Validators
ACF.Permissions = Policies.Permissions
ACF.Ownership = Policies.Ownership
-- Advanced: construct isolated instances with a custom Environment.
ACF.Framework = Framework

-- Combat / game-rule integration. Assigned explicitly so strict-mode games see the types.
local integration = IntegrationAPI.create(framework)
ACF.CombatClaim = Combat.ClaimValidator
ACF.DefineWeapon = integration.DefineWeapon
ACF.DefineAbility = integration.DefineAbility
ACF.SetCombatProvider = integration.SetCombatProvider
ACF.ValidateAttack = integration.ValidateAttack
ACF.FireProjectile = integration.FireProjectile
ACF.ValidateProjectileHit = integration.ValidateProjectileHit
ACF.Reload = integration.Reload
ACF.GetAmmo = integration.GetAmmo
ACF.SetAmmo = integration.SetAmmo
ACF.GetCombatStats = integration.GetCombatStats
ACF.DefineSignal = integration.DefineSignal
ACF.RecordSignal = integration.RecordSignal
ACF.RecordAction = integration.RecordAction
ACF.GetBehaviorProfile = integration.GetBehaviorProfile
ACF.GetBehaviorStats = integration.GetBehaviorStats

local function remoteSecurity(): any
	local current = framework()
	if current:GetState() == "Created" then
		error("ACF: call ACF:Initialize before protecting remotes", 3)
	end
	if current:GetConfig("Modules").RemoteSecurity == false then
		error("ACF: the RemoteSecurity module is disabled (Modules.RemoteSecurity = false)", 3)
	end
	return current:GetModule("RemoteSecurity")
end

-- Validates and applies configuration. Raises with every problem listed if invalid;
-- the call can be retried with corrected configuration.
function ACF.Initialize(_self: any, config: { [string]: any }?)
	framework():Initialize(config)
end

-- Registers a detection module (see docs/MODULES.md). Call before Start.
function ACF.RegisterModule(_self: any, definition: any)
	framework():RegisterModule(definition)
end

function ACF.Start(_self: any): { [string]: any }
	return framework():Start()
end

function ACF.Stop(_self: any)
	if instance then
		instance:Stop()
	end
end

function ACF.GetStatus(_self: any): { [string]: any }
	return framework():GetStatus()
end

function ACF.GetSession(_self: any, player: any)
	return framework():GetSession(player)
end

function ACF.GetEvidence(_self: any, player: any, filter: any?)
	return framework():GetEvidence(player, filter)
end

function ACF.GetEvidenceSummary(_self: any, player: any)
	return framework():GetEvidenceSummary(player)
end

function ACF.OnDetection(_self: any, handler: (any) -> ())
	return framework():OnDetection(handler)
end

-- Risk (docs/RISK.md) ----------------------------------------------------------------

-- { UserId, Risk (0-100), Band, Confidence, Persistent, Peak, Groups, Explanation }
function ACF.GetRisk(_self: any, player: any)
	return framework():GetRisk(player)
end

function ACF.GetRiskHistory(_self: any, player: any)
	return framework():GetRiskHistory(player)
end

-- Staff override. options = { Persistent = true?, Reason = "..." }.
function ACF.ResetRisk(_self: any, player: any, options: { Persistent: boolean?, Reason: string? }?)
	framework():ResetRisk(player, options)
end

-- Enforcement (docs/ENFORCEMENT.md) --------------------------------------------------
-- Staff actions require options.By (who is acting); everything is audited.

-- { Level, LevelName, Tags, RestrictedFor, Shadow, Override, OpenCase, Ban, History }
function ACF.GetEnforcement(_self: any, player: any)
	return framework():GetEnforcement(player)
end

-- For game code: is this player restricted for `tag` (a risk group, e.g. "Economy")?
function ACF.IsRestricted(_self: any, player: any, tag: string | boolean, operation: string?): boolean
	return framework():IsRestricted(player, tag, operation)
end

-- Returns the appeal reference.
function ACF.Kick(_self: any, player: any, options: { By: any, Reason: string? }): string
	return framework():Kick(player, options)
end

-- options.Hours = nil bans permanently. Works for players who are offline. Returns the appeal reference.
function ACF.Ban(_self: any, player: any, options: { By: any, Reason: string?, Hours: number? }): string
	return framework():Ban(player, options)
end

function ACF.Unban(_self: any, player: any, options: { By: any, Reason: string? })
	framework():Unban(player, options)
end

-- options: { Exempt = true } or { Level = 0-4 }, plus Seconds?, By, Reason?.
function ACF.SetEnforcementOverride(_self: any, player: any, options: { [string]: any })
	framework():SetEnforcementOverride(player, options)
end

function ACF.ClearEnforcementOverride(_self: any, player: any, options: { By: any, Reason: string? })
	framework():ClearEnforcementOverride(player, options)
end

-- callback({ UserId, Ban, History }) once the stored record has loaded.
function ACF.LoadEnforcementRecord(_self: any, player: any, callback: (any) -> ())
	framework():LoadEnforcementRecord(player, callback)
end

function ACF.GetCases(_self: any, filter: { Status: string?, UserId: number? }?)
	return framework():GetCases(filter)
end

function ACF.ApproveCase(_self: any, caseId: string, options: { By: any, Level: number?, Note: string?, Hours: number? })
	framework():ApproveCase(caseId, options)
end

function ACF.RejectCase(_self: any, caseId: string, options: { By: any, Note: string? })
	framework():RejectCase(caseId, options)
end

function ACF.GetAuditLog(_self: any, filter: { UserId: number?, Type: string?, Since: number? }?)
	return framework():GetAuditLog(filter)
end

function ACF.OnEnforcementCase(_self: any, handler: (any) -> ())
	return framework():Subscribe(ACF.Topics.EnforcementCase, handler)
end

function ACF.OnEnforcementAudit(_self: any, handler: (any) -> ())
	return framework():Subscribe(ACF.Topics.EnforcementAudit, handler)
end

-- handler({ UserId, Session, Risk, Previous, Band, PreviousBand, Confidence, Explanation })
-- whenever a player's risk band changes.
function ACF.OnRiskChanged(_self: any, handler: (any) -> ())
	return framework():Subscribe(ACF.Topics.RiskChanged, handler)
end

function ACF.Subscribe(_self: any, topic: string, handler: (any) -> ())
	return framework():Subscribe(topic, handler)
end

-- Protects a RemoteEvent / UnreliableRemoteEvent. See docs/REMOTE_SECURITY.md.
-- Returns a handle with Unprotect().
function ACF.ProtectEvent(_self: any, remote: any, spec: any)
	return remoteSecurity():ProtectEvent(remote, spec)
end

-- Protects a RemoteFunction. Returns a handle with Unprotect().
function ACF.ProtectFunction(_self: any, remote: any, spec: any)
	return remoteSecurity():ProtectFunction(remote, spec)
end

local function movement(): any
	local current = framework()
	if current:GetState() ~= "Running" then
		error("ACF: movement allowances require ACF:Start()", 3)
	end
	if current:GetModuleState("Movement") ~= "Running" then
		error("ACF: the Movement module is not running", 3)
	end
	return current:GetModule("Movement")
end

-- Call right before the server moves a character (PivotTo, spawn points, portals).
-- Suppresses teleport/speed/noclip checks for `seconds` (default 1).
function ACF.AuthorizeTeleport(_self: any, player: Player, seconds: number?): boolean
	return movement():AuthorizeTeleport(player, seconds)
end

-- Temporary allowance for a game mechanic. kind: "Teleport" | "Speed" | "Flight" |
-- "Noclip" | "Impulse" | "All". For "Speed", options.Multiplier (default 2).
function ACF.AllowMovement(_self: any, player: Player, kind: string, seconds: number, options: { Multiplier: number? }?): boolean
	return movement():Allow(player, kind, seconds, options)
end

-- Lists RemoteEvents/RemoteFunctions under root that ACF does not protect.
function ACF.FindUnprotectedRemotes(_self: any, root: Instance): { Instance }
	return remoteSecurity():FindUnprotected(root)
end

function ACF.GetRemoteStats(_self: any): { [string]: any }
	return remoteSecurity():GetStats()
end

function ACF.GetConfig(_self: any, path: string): any
	return framework():GetConfig(path)
end

function ACF.GetRecentLogs(_self: any, count: number?)
	return framework():GetRecentLogs(count)
end

return ACF
