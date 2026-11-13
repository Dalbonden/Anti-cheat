--!strict
--[[
	Central interval scheduler.

	Instead of every detector connecting its own Heartbeat handler, modules register
	interval tasks here. One Heartbeat connection drives Step(), which runs whichever
	tasks are due. This gives one place to measure per-task CPU cost, isolate errors and
	disable tasks that keep failing.

	Semantics:
	  - Every(name, interval, fn): fn(now, dt) runs roughly every `interval` seconds. If the
	    server stalls, missed runs are skipped rather than replayed in a burst.
	  - After(name, delay, fn): one-shot.
	  - A repeating task that fails MaxConsecutiveFailures times in a row is disabled and
	    logged at Error level.
	  - Statistics are aggregated by task name, so memory stays bounded by the number of
	    distinct names (which are defined in code).
]]

local Logger = require(script.Parent.Logger)

type Logger = Logger.Logger

type Task = {
	Name: string,
	Interval: number?,
	NextRun: number,
	LastRun: number,
	Callback: (now: number, dt: number) -> (),
	Active: boolean,
	ConsecutiveFailures: number,
}

export type TaskStats = {
	Runs: number,
	Failures: number,
	Disabled: number,
	TotalCpuSeconds: number,
	MaxCpuSeconds: number,
}

export type TaskHandle = {
	Name: string,
	Cancel: (self: TaskHandle) -> (),
	IsActive: (self: TaskHandle) -> boolean,
	-- Alias of Cancel so handles can be added to a Cleanup bag.
	Disconnect: (self: TaskHandle) -> (),
}

local Scheduler = {}
Scheduler.__index = Scheduler

export type Scheduler = typeof(setmetatable(
	{} :: {
		_now: () -> number,
		_cpu: () -> number,
		_logger: Logger,
		_maxFailures: number,
		_tasks: { Task },
		_stats: { [string]: TaskStats },
		_stepping: boolean,
		_binding: any?,
		_steps: number,
	},
	Scheduler
))

export type SchedulerOptions = {
	Now: () -> number,
	CpuClock: (() -> number)?,
	Logger: Logger,
	MaxConsecutiveFailures: number?,
}

function Scheduler.new(options: SchedulerOptions): Scheduler
	return setmetatable({
		_now = options.Now,
		_cpu = options.CpuClock or os.clock,
		_logger = options.Logger,
		_maxFailures = options.MaxConsecutiveFailures or 5,
		_tasks = {},
		_stats = {},
		_stepping = false,
		_binding = nil,
		_steps = 0,
	}, Scheduler)
end

local function isPositiveFinite(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and value < math.huge
end

local function makeHandle(entry: Task): TaskHandle
	local function cancel()
		entry.Active = false
	end
	return {
		Name = entry.Name,
		Cancel = cancel,
		Disconnect = cancel,
		IsActive = function()
			return entry.Active
		end,
	}
end

local function addTask(self: Scheduler, name: string, interval: number?, firstDelay: number, callback): TaskHandle
	if type(name) ~= "string" or #name == 0 then
		error("Scheduler: task name must be a non-empty string", 3)
	end
	if type(callback) ~= "function" then
		error("Scheduler: callback must be a function", 3)
	end
	local now = self._now()
	local entry: Task = {
		Name = name,
		Interval = interval,
		NextRun = now + firstDelay,
		LastRun = now,
		Callback = callback,
		Active = true,
		ConsecutiveFailures = 0,
	}
	table.insert(self._tasks, entry)
	if self._stats[name] == nil then
		self._stats[name] = { Runs = 0, Failures = 0, Disabled = 0, TotalCpuSeconds = 0, MaxCpuSeconds = 0 }
	end
	return makeHandle(entry)
end

-- Runs callback(now, dt) every `interval` seconds. `phase` delays the first run
-- (defaults to one interval) and can be used to spread tasks with equal intervals.
function Scheduler.Every(
	self: Scheduler,
	name: string,
	interval: number,
	callback: (now: number, dt: number) -> (),
	phase: number?
): TaskHandle
	if not isPositiveFinite(interval) then
		error("Scheduler:Every interval must be a positive finite number", 2)
	end
	local first = phase or interval
	if type(first) ~= "number" or first < 0 or first ~= first then
		error("Scheduler:Every phase must be a non-negative number", 2)
	end
	return addTask(self, name, interval, first, callback)
end

function Scheduler.After(self: Scheduler, name: string, delay: number, callback: (now: number, dt: number) -> ()): TaskHandle
	if type(delay) ~= "number" or delay < 0 or delay ~= delay or delay == math.huge then
		error("Scheduler:After delay must be a non-negative finite number", 2)
	end
	return addTask(self, name, nil, delay, callback)
end

function Scheduler.Step(self: Scheduler)
	if self._stepping then
		return
	end
	self._stepping = true
	self._steps += 1
	local now = self._now()
	local tasks = self._tasks
	local count = #tasks
	local anyInactive = false

	for i = 1, count do
		local entry = tasks[i]
		if entry.Active and now >= entry.NextRun then
			local dt = now - entry.LastRun
			entry.LastRun = now
			local interval = entry.Interval
			if interval then
				entry.NextRun += interval
				if entry.NextRun <= now then
					-- Fell behind (server stall): skip missed runs.
					entry.NextRun = now + interval
				end
			else
				entry.Active = false
			end

			local stats = self._stats[entry.Name]
			local started = self._cpu()
			local ok: boolean, err: any = pcall(entry.Callback, now, dt)
			local spent = self._cpu() - started
			stats.Runs += 1
			stats.TotalCpuSeconds += spent
			if spent > stats.MaxCpuSeconds then
				stats.MaxCpuSeconds = spent
			end

			if ok then
				entry.ConsecutiveFailures = 0
			else
				stats.Failures += 1
				entry.ConsecutiveFailures += 1
				self._logger:Error("Scheduled task failed", {
					Task = entry.Name,
					Error = tostring(err),
					ConsecutiveFailures = entry.ConsecutiveFailures,
				})
				if interval and entry.ConsecutiveFailures >= self._maxFailures then
					entry.Active = false
					stats.Disabled += 1
					self._logger:Error("Scheduled task disabled after repeated failures", { Task = entry.Name })
				end
			end
		end
		if not entry.Active then
			anyInactive = true
		end
	end

	if anyInactive then
		local kept = {}
		for _, entry in tasks do
			if entry.Active then
				table.insert(kept, entry)
			end
		end
		self._tasks = kept
	end
	self._stepping = false
end

-- Connects Step() to a per-frame signal (RunService.Heartbeat in production).
function Scheduler.Bind(self: Scheduler, signal: any)
	if self._binding then
		error("Scheduler is already bound to a signal", 2)
	end
	self._binding = signal:Connect(function()
		self:Step()
	end)
end

function Scheduler.Unbind(self: Scheduler)
	local binding = self._binding
	if binding then
		binding:Disconnect()
		self._binding = nil
	end
end

function Scheduler.IsBound(self: Scheduler): boolean
	return self._binding ~= nil
end

function Scheduler.ActiveCount(self: Scheduler): number
	local n = 0
	for _, entry in self._tasks do
		if entry.Active then
			n += 1
		end
	end
	return n
end

function Scheduler.GetStats(self: Scheduler): { [string]: TaskStats }
	local copy = {}
	for name, stats in self._stats do
		copy[name] = table.freeze(table.clone(stats))
	end
	return copy
end

function Scheduler.CancelAll(self: Scheduler)
	for _, entry in self._tasks do
		entry.Active = false
	end
	table.clear(self._tasks)
end

function Scheduler.Destroy(self: Scheduler)
	self:Unbind()
	self:CancelAll()
end

return Scheduler
