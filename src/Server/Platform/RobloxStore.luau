--!strict
--[[
	Roblox implementation of Environment.Store (DataStoreService).

	Each Load/Save runs in its own thread (task.spawn) so callers never yield, and every
	DataStore call is wrapped in pcall: failures reach the callback as (false, message)
	and never raise. Retries and batching are the caller's job (RiskEngine), so they are
	covered by the offline tests.

	GetDataStore itself can fail (Studio without "Enable Studio Access to API Services",
	or a place without DataStore access); that is reported the same way.

	Studio-only code path; verify with the Studio run.
]]

local Types = require(script.Parent.Parent.Types)

local RobloxStore = {}

function RobloxStore.create(): Types.KeyValueStore
	local DataStoreService = game:GetService("DataStoreService")
	local stores: { [string]: any } = {}

	local function storeFor(scope: string): (boolean, any)
		local cached = stores[scope]
		if cached then
			return true, cached
		end
		local ok, result = pcall(function()
			return DataStoreService:GetDataStore(scope)
		end)
		if ok then
			stores[scope] = result
		end
		return ok, result
	end

	local service = {}

	function service.Load(_self: any, scope: string, key: string, callback: (boolean, any, string?) -> ())
		task.spawn(function()
			local ok, store = storeFor(scope)
			if not ok then
				callback(false, nil, tostring(store))
				return
			end
			local loaded, value = pcall(function()
				return store:GetAsync(key)
			end)
			if loaded then
				callback(true, value, nil)
			else
				callback(false, nil, tostring(value))
			end
		end)
	end

	function service.Save(_self: any, scope: string, key: string, value: any, callback: (boolean, string?) -> ())
		task.spawn(function()
			local ok, store = storeFor(scope)
			if not ok then
				callback(false, tostring(store))
				return
			end
			local saved, err = pcall(function()
				store:SetAsync(key, value)
			end)
			callback(saved, if saved then nil else tostring(err))
		end)
	end

	return service :: any
end

return RobloxStore
