--!strict
--[[
	Resource cleanup bag.

	Collects things that must be released later and releases them in reverse order of
	acquisition. Accepted tasks:
	  - functions (called)
	  - threads (cancelled with task.cancel)
	  - RBXScriptConnections and tables with a Disconnect method
	  - Instances and tables with a Destroy method

	A failing task never prevents the remaining tasks from running; failures are passed
	to the optional onError callback and counted in Clean()'s return value.
]]

local Cleanup = {}
Cleanup.__index = Cleanup

export type Cleanup = typeof(setmetatable(
	{} :: {
		_tasks: { any },
		_onError: ((message: string) -> ())?,
	},
	Cleanup
))

local function isValidTask(item: any): boolean
	local kind = typeof(item)
	if kind == "function" or kind == "thread" or kind == "Instance" or kind == "RBXScriptConnection" then
		return true
	end
	if kind == "table" then
		return type(item.Disconnect) == "function" or type(item.Destroy) == "function"
	end
	return false
end

local function runTask(item: any)
	local kind = typeof(item)
	if kind == "function" then
		item()
	elseif kind == "thread" then
		if coroutine.status(item) ~= "dead" then
			task.cancel(item)
		end
	elseif kind == "RBXScriptConnection" then
		item:Disconnect()
	elseif kind == "Instance" then
		item:Destroy()
	elseif type(item.Disconnect) == "function" then
		item:Disconnect()
	else
		item:Destroy()
	end
end

function Cleanup.new(onError: ((message: string) -> ())?): Cleanup
	return setmetatable({ _tasks = {}, _onError = onError }, Cleanup)
end

-- Adds a task and returns it unchanged, so acquisition can be written inline:
--   local conn = bag:Add(signal:Connect(fn))
function Cleanup.Add(self: Cleanup, item: any): any
	if not isValidTask(item) then
		error(`Cleanup:Add received an unsupported value of type '{typeof(item)}'`, 2)
	end
	table.insert(self._tasks, item)
	return item
end

-- Removes a task without running it. Returns true if it was present.
function Cleanup.Remove(self: Cleanup, item: any): boolean
	local index = table.find(self._tasks, item)
	if index then
		table.remove(self._tasks, index)
		return true
	end
	return false
end

-- Runs all tasks in reverse order. Tasks added while cleaning are also run.
-- Returns the number of tasks that raised an error.
function Cleanup.Clean(self: Cleanup): number
	local failures = 0
	local tasks = self._tasks
	while #tasks > 0 do
		local item = table.remove(tasks)
		local ok: boolean, err: any = pcall(runTask, item)
		if not ok then
			failures += 1
			local onError = self._onError
			if onError then
				pcall(onError, tostring(err))
			end
		end
	end
	return failures
end

function Cleanup.Count(self: Cleanup): number
	return #self._tasks
end

-- Alias so a Cleanup can itself be added to another Cleanup.
function Cleanup.Destroy(self: Cleanup)
	self:Clean()
end

return Cleanup
