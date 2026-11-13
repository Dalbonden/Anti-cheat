--!strict
--[[
	Keyed token-bucket rate limiter with bounded key storage.

	Each key gets a bucket of `capacity` tokens that refills continuously at
	`refillPerSecond`. Allow() spends tokens. Buckets that have refilled completely carry
	no information and are pruned when the key table reaches `maxKeys`. If pruning cannot
	free space, all buckets are reset (bounded memory beats perfect accounting); this is
	counted in GetStats().Overflows.
]]

type Bucket = { tokens: number, updated: number }

local RateLimiter = {}
RateLimiter.__index = RateLimiter

export type RateLimiter = typeof(setmetatable(
	{} :: {
		_capacity: number,
		_refill: number,
		_now: () -> number,
		_maxKeys: number,
		_buckets: { [string]: Bucket },
		_keyCount: number,
		_overflows: number,
	},
	RateLimiter
))

function RateLimiter.new(capacity: number, refillPerSecond: number, now: () -> number, maxKeys: number?): RateLimiter
	assert(type(capacity) == "number" and capacity >= 1, "RateLimiter: capacity must be >= 1")
	assert(type(refillPerSecond) == "number" and refillPerSecond > 0, "RateLimiter: refill rate must be > 0")
	assert(type(now) == "function", "RateLimiter: now must be a function")
	return setmetatable({
		_capacity = capacity,
		_refill = refillPerSecond,
		_now = now,
		_maxKeys = maxKeys or 1024,
		_buckets = {},
		_keyCount = 0,
		_overflows = 0,
	}, RateLimiter)
end

local function refilled(self: RateLimiter, bucket: Bucket, now: number): number
	local elapsed = now - bucket.updated
	if elapsed <= 0 then
		return bucket.tokens
	end
	return math.min(self._capacity, bucket.tokens + elapsed * self._refill)
end

function RateLimiter.Allow(self: RateLimiter, key: string, cost: number?): boolean
	local price = cost or 1
	local now = self._now()
	local bucket = self._buckets[key]
	if bucket == nil then
		if self._keyCount >= self._maxKeys then
			self:Prune()
		end
		bucket = { tokens = self._capacity, updated = now }
		self._buckets[key] = bucket
		self._keyCount += 1
	else
		bucket.tokens = refilled(self, bucket, now)
		bucket.updated = now
	end
	if bucket.tokens >= price then
		bucket.tokens -= price
		return true
	end
	return false
end

-- Removes buckets that have fully refilled. Resets everything if still at capacity.
function RateLimiter.Prune(self: RateLimiter)
	local now = self._now()
	for key, bucket in self._buckets do
		if refilled(self, bucket, now) >= self._capacity then
			self._buckets[key] = nil
			self._keyCount -= 1
		end
	end
	if self._keyCount >= self._maxKeys then
		table.clear(self._buckets)
		self._keyCount = 0
		self._overflows += 1
	end
end

function RateLimiter.Reset(self: RateLimiter, key: string?)
	if key == nil then
		table.clear(self._buckets)
		self._keyCount = 0
	elseif self._buckets[key] ~= nil then
		self._buckets[key] = nil
		self._keyCount -= 1
	end
end

function RateLimiter.GetStats(self: RateLimiter): { Keys: number, Overflows: number }
	return { Keys = self._keyCount, Overflows = self._overflows }
end

return RateLimiter
