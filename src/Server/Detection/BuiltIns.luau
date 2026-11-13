--!strict
--[[
	Built-in modules shipped with ACF, registered automatically by Framework:Initialize
	before any user module, in this order. Each entry is a factory returning a fresh
	module definition. Disable one with Modules = { <Name> = false }; enable an opt-in
	one (Telemetry) with Modules = { Telemetry = true }.
]]

local Movement = require(script.Parent.Movement.Movement)
local Physics = require(script.Parent.Physics.Physics)
local RemoteSecurity = require(script.Parent.RemoteSecurity.RemoteSecurity)
local Telemetry = require(script.Parent.Telemetry.Telemetry)

return table.freeze({
	RemoteSecurity.new,
	Movement.new,
	Physics.new,
	Telemetry.new,
})
