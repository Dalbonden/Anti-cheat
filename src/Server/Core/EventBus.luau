--!strict
--[[
	Synchronous, error-isolated publish/subscribe bus.

	- Delivery is synchronous and in subscription order, so behaviour is deterministic
	  and testable. Handlers must not yield; spawn a thread yourself for slow work.
	- Every handler runs in pcall. A failing handler is logged and, after
	  MaxHandlerFailures consecutive failures, disconnected so one broken subscriber
	  cannot flood logs or degrade the server.
	- In strict mode (the framework default) publishing or subscribing to an
	  unregistered topic raises an error, which catches typos at development time.
	- Re-entrant publishes are allowed up to MaxDispatchDepth to stop runaway loops.
]]

local Logger = require(script.Parent.Logger)

type Logger = Logger.Logger

export type Subscription = {
	Connected: boolean,
	Topic: string,
	Owner: string,
	Disconnect: (self: Subscription) -> (),
}

type InternalSubscription = Subscription & {
	_handler: (any) -> (),
	_failures: number,
}

local EventBus = {}
EventBus.__index = EventBus

export type EventBus = typeof(setmetatable(
	{} :: {
		_logger: Logger,
		_strict: boolean,
		_maxFailures: number,
		_maxDepth: number,
		_topics: { [string]: boolean },
		_subscriptions: { [string]: { InternalSubscription } },
		_dirty: { [string]: boolean },
		_depth: number,
		_destroyed: boolean,
		_published: number,
		_handlerErrors: number,
	},
	EventBus
))

export type EventBusOptions = {
	Logger: Logger,
	Strict: boolean?,
	MaxHandlerFailures: number?,
	MaxDispatchDepth: number?,
}

function EventBus.new(options: EventBusOptions): EventBus
	return setmetatable({
		_logger = options.Logger,
		_strict = options.Strict ~= false,
		_maxFailures = options.MaxHandlerFailures or 10,
		_maxDepth = options.MaxDispatchDepth or 8,
		_topics = {},
		_subscriptions = {},
		_dirty = {},
		_depth = 0,
		_destroyed = false,
		_published = 0,
		_handlerErrors = 0,
	}, EventBus)
end

function EventBus.RegisterTopic(self: EventBus, topic: string)
	if type(topic) ~= "string" or #topic == 0 then
		error("EventBus:RegisterTopic expects a non-empty string", 2)
	end
	self._topics[topic] = true
end

function EventBus.HasTopic(self: EventBus, topic: string): boolean
	return self._topics[topic] == true
end

local function checkTopic(self: EventBus, topic: string, level: number)
	if type(topic) ~= "string" then
		error("EventBus: topic must be a string", level + 1)
	end
	if self._strict and not self._topics[topic] then
		error(`EventBus: unknown topic '{topic}'`, level + 1)
	end
end

local function compact(self: EventBus, topic: string)
	local list = self._subscriptions[topic]
	if list then
		local kept = {}
		for _, sub in list do
			if sub.Connected then
				table.insert(kept, sub)
			end
		end
		self._subscriptions[topic] = kept
	end
	self._dirty[topic] = nil
end

function EventBus.Subscribe(self: EventBus, topic: string, handler: (any) -> (), owner: string?): Subscription
	checkTopic(self, topic, 2)
	if type(handler) ~= "function" then
		error("EventBus:Subscribe expects a handler function", 2)
	end
	if self._destroyed then
		error("EventBus:Subscribe called on a destroyed bus", 2)
	end

	local bus = self
	local sub: InternalSubscription
	sub = {
		Connected = true,
		Topic = topic,
		Owner = owner or "anonymous",
		_handler = handler,
		_failures = 0,
		Disconnect = function(_self: Subscription)
			if not sub.Connected then
				return
			end
			sub.Connected = false
			if bus._depth > 0 then
				bus._dirty[topic] = true
			else
				compact(bus, topic)
			end
		end,
	} :: any

	local list = self._subscriptions[topic]
	if list == nil then
		list = {}
		self._subscriptions[topic] = list
	end
	table.insert(list, sub)
	return sub
end

-- Delivers payload to every connected subscriber of topic. Returns the number of
-- handlers that completed without error.
function EventBus.Publish(self: EventBus, topic: string, payload: any): number
	checkTopic(self, topic, 2)
	if self._destroyed then
		return 0
	end
	local list = self._subscriptions[topic]
	if list == nil or #list == 0 then
		self._published += 1
		return 0
	end
	if self._depth >= self._maxDepth then
		self._logger:Error("Dispatch depth exceeded; event dropped", { Topic = topic, Depth = self._depth })
		return 0
	end

	self._published += 1
	self._depth += 1
	local delivered = 0
	-- Snapshot the length: subscribers added during dispatch receive the next event.
	for i = 1, #list do
		local sub = list[i]
		if sub.Connected then
			local ok: boolean, err: any = pcall(sub._handler, payload)
			if ok then
				delivered += 1
				sub._failures = 0
			else
				self._handlerErrors += 1
				sub._failures += 1
				self._logger:Error("Event handler failed", {
					Topic = topic,
					Owner = sub.Owner,
					Error = tostring(err),
					ConsecutiveFailures = sub._failures,
				})
				if sub._failures >= self._maxFailures then
					sub:Disconnect()
					self._logger:Error("Event handler disconnected after repeated failures", {
						Topic = topic,
						Owner = sub.Owner,
					})
				end
			end
		end
	end
	self._depth -= 1

	if self._depth == 0 then
		for dirtyTopic in self._dirty do
			compact(self, dirtyTopic)
		end
	end
	return delivered
end

function EventBus.SubscriberCount(self: EventBus, topic: string): number
	local list = self._subscriptions[topic]
	if list == nil then
		return 0
	end
	local count = 0
	for _, sub in list do
		if sub.Connected then
			count += 1
		end
	end
	return count
end

function EventBus.GetStats(self: EventBus): { Published: number, HandlerErrors: number, Topics: number }
	local topics = 0
	for _ in self._topics do
		topics += 1
	end
	return { Published = self._published, HandlerErrors = self._handlerErrors, Topics = topics }
end

function EventBus.Destroy(self: EventBus)
	for _, list in self._subscriptions do
		for _, sub in list do
			sub.Connected = false
		end
	end
	table.clear(self._subscriptions)
	table.clear(self._dirty)
	self._destroyed = true
end

return EventBus
