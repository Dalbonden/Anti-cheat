--!strict
--[[
	Built-in modules shipped with ACF, registered automatically by Framework:Initialize
	before any user module. Each entry is a factory returning a fresh module definition.
	Disable one with Modules = { <Name> = false }.
]]

local RemoteSecurity = require(script.Parent.RemoteSecurity.RemoteSecurity)

return table.freeze({
	RemoteSecurity.new,
})
