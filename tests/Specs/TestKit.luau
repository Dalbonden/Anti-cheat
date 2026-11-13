--[[
	Minimal dependency-free test framework that runs identically in Lune and Roblox.

	Spec modules return function(t) and use:
		t.describe(name, fn)   t.it(name, fn)   t.beforeEach(fn)   t.afterEach(fn)
		t.expect(value).toBe(x) / toEqual(x) / toBeNil() / toBeTruthy() / toBeFalsy()
		  / toBeGreaterThan(n) / toBeLessThan(n) / toBeCloseTo(n, eps?) / toContain(x)
		  / toHaveLength(n) / toThrow(substring?) / never.toBe(x) / never.toThrow()
]]

local TestKit = {}

local function render(value: any, depth: number?): string
	local level = depth or 0
	if type(value) == "string" then
		return string.format("%q", value)
	end
	if type(value) ~= "table" or level > 2 then
		return tostring(value)
	end
	local parts = {}
	local count = 0
	for k, v in value do
		count += 1
		if count > 8 then
			table.insert(parts, "...")
			break
		end
		table.insert(parts, `{tostring(k)}={render(v, level + 1)}`)
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

local function deepEqual(a: any, b: any, seen: { [any]: any }?): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	local visited = seen or {}
	if visited[a] == b then
		return true
	end
	visited[a] = b
	for k, v in a do
		if not deepEqual(v, b[k], visited) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function fail(message: string)
	error({ __testFailure = true, message = message }, 0)
end

local function makeExpect(actual: any, negate: boolean)
	local function check(passed: boolean, message: string)
		if negate then
			passed = not passed
			message = "NOT: " .. message
		end
		if not passed then
			fail(message)
		end
	end

	local matchers = {}

	function matchers.toBe(expected: any)
		check(actual == expected, `expected {render(actual)} to be {render(expected)}`)
	end

	function matchers.toEqual(expected: any)
		check(deepEqual(actual, expected), `expected {render(actual)} to deep-equal {render(expected)}`)
	end

	function matchers.toBeNil()
		check(actual == nil, `expected {render(actual)} to be nil`)
	end

	function matchers.toBeTruthy()
		check(not not actual, `expected {render(actual)} to be truthy`)
	end

	function matchers.toBeFalsy()
		check(not actual, `expected {render(actual)} to be falsy`)
	end

	function matchers.toBeGreaterThan(n: number)
		check(type(actual) == "number" and actual > n, `expected {render(actual)} > {n}`)
	end

	function matchers.toBeLessThan(n: number)
		check(type(actual) == "number" and actual < n, `expected {render(actual)} < {n}`)
	end

	function matchers.toBeCloseTo(n: number, epsilon: number?)
		local eps = epsilon or 1e-6
		check(type(actual) == "number" and math.abs(actual - n) <= eps, `expected {render(actual)} to be within {eps} of {n}`)
	end

	function matchers.toContain(item: any)
		local found = false
		if type(actual) == "string" then
			found = string.find(actual, tostring(item), 1, true) ~= nil
		elseif type(actual) == "table" then
			for _, v in actual do
				if v == item then
					found = true
					break
				end
			end
		end
		check(found, `expected {render(actual)} to contain {render(item)}`)
	end

	function matchers.toHaveLength(n: number)
		local length = if type(actual) == "table" or type(actual) == "string" then #actual else -1
		check(length == n, `expected length {n}, got {length}`)
	end

	function matchers.toThrow(substring: string?)
		if type(actual) ~= "function" then
			fail("toThrow expects a function")
		end
		local ok, err = pcall(actual)
		local message = if type(err) == "table" and err.message then err.message else tostring(err)
		if negate then
			check(not ok, `expected function to throw, but it raised: {message}`)
			return
		end
		if ok then
			fail("expected function to throw, but it did not")
		end
		if substring and not string.find(message, substring, 1, true) then
			fail(`expected error containing {render(substring)}, got {render(message)}`)
		end
	end

	return matchers
end

function TestKit.expect(actual: any)
	local matchers = makeExpect(actual, false)
	matchers.never = makeExpect(actual, true)
	return matchers
end

type TestNode = {
	name: string,
	fn: (() -> ())?,
	children: { TestNode },
	beforeEach: { () -> () },
	afterEach: { () -> () },
}

-- Collects tests from spec functions, then runs them. Returns a results table.
function TestKit.run(specs: { { name: string, spec: (any) -> () } }, options: { Filter: string?, Print: ((string) -> ())? }?)
	local opts = options or {}
	local out = opts.Print or print
	local results = { Total = 0, Passed = 0, Failed = 0, Failures = {} }

	for _, item in specs do
		local root: TestNode = { name = item.name, children = {}, beforeEach = {}, afterEach = {} }
		local stack = { root }
		local t = {
			expect = TestKit.expect,
			describe = function(name: string, fn: () -> ())
				local node: TestNode = { name = name, children = {}, beforeEach = {}, afterEach = {} }
				table.insert(stack[#stack].children, node)
				table.insert(stack, node)
				fn()
				table.remove(stack)
			end,
			it = function(name: string, fn: () -> ())
				table.insert(stack[#stack].children, { name = name, fn = fn, children = {}, beforeEach = {}, afterEach = {} })
			end,
			beforeEach = function(fn: () -> ())
				table.insert(stack[#stack].beforeEach, fn)
			end,
			afterEach = function(fn: () -> ())
				table.insert(stack[#stack].afterEach, fn)
			end,
		}

		local collected, collectErr = pcall(item.spec, t)
		if not collected then
			results.Total += 1
			results.Failed += 1
			table.insert(results.Failures, { Name = item.name .. " (collect)", Message = tostring(collectErr) })
		else
			local function walk(node: TestNode, path: { string }, befores: { () -> () }, afters: { () -> () })
				local myBefores = table.clone(befores)
				for _, fn in node.beforeEach do
					table.insert(myBefores, fn)
				end
				local myAfters = table.clone(node.afterEach)
				for _, fn in afters do
					table.insert(myAfters, fn)
				end
				for _, child in node.children do
					local childPath = table.clone(path)
					table.insert(childPath, child.name)
					local testFn = child.fn
					if testFn then
						local fullName = table.concat(childPath, " > ")
						if opts.Filter == nil or string.find(fullName, opts.Filter, 1, true) then
							results.Total += 1
							local ok, err = xpcall(function()
								for _, before in myBefores do
									before()
								end
								testFn()
							end, function(e)
								if type(e) == "table" and e.__testFailure then
									return e.message
								end
								return debug.traceback(tostring(e), 2)
							end)
							for _, after in myAfters do
								local afterOk, afterErr = pcall(after)
								if ok and not afterOk then
									ok, err = false, "afterEach: " .. tostring(afterErr)
								end
							end
							if ok then
								results.Passed += 1
							else
								results.Failed += 1
								table.insert(results.Failures, { Name = fullName, Message = tostring(err) })
							end
						end
					else
						walk(child, childPath, myBefores, myAfters)
					end
				end
			end
			walk(root, { root.name }, {}, {})
		end
	end

	for _, failure in results.Failures do
		out(`FAIL  {failure.Name}\n      {string.gsub(failure.Message, "\n", "\n      ")}`)
	end
	out(`\n{results.Passed}/{results.Total} passed, {results.Failed} failed`)
	return results
end

return TestKit
