--!strict
--[[
	ACF shared constants.

	This module replicates to clients. Only put values here that are safe for an
	exploiter to read: never thresholds, enforcement policy, secrets or trusted state.
]]

local Constants = table.freeze({
	FRAMEWORK_NAME = "ACF",
	VERSION = "0.1.0",
})

return Constants
