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
local DetectionManager = require(script.Parent.Parent.Detection.DetectionManager)
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
-- Advanced: construct isolated instances with a custom Environment.
ACF.Framework = Framework

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

function ACF.Subscribe(_self: any, topic: string, handler: (any) -> ())
	return framework():Subscribe(topic, handler)
end

function ACF.GetConfig(_self: any, path: string): any
	return framework():GetConfig(path)
end

function ACF.GetRecentLogs(_self: any, count: number?)
	return framework():GetRecentLogs(count)
end

return ACF
