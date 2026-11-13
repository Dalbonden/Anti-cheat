--!strict
--[[
	Composable argument validators for remote requests.

	Everything a client sends is attacker-controlled. Validators therefore:
	  - use secure defaults (strings <= 256 chars and valid UTF-8, arrays <= 64 items,
	    maps <= 32 entries, NaN and infinity rejected);
	  - bound their work: tables are walked with an entry budget, so a huge table costs
	    at most `limit + 1` iterations before rejection;
	  - never throw on hostile input (the caller also wraps them in pcall);
	  - never echo attacker-supplied text in error messages. Paths use schema field
	    names, and only value *types* are described.

	A validator is a frozen table { Kind, Description, Check } where
	Check(value, path) returns (true) or (false, message).

		local V = ACF.Validators
		V.struct({ ItemId = V.string({ MaxLength = 32 }), Quantity = V.integer({ Min = 1, Max = 99 }) })
]]

export type CheckFn = (value: any, path: string) -> (boolean, string?)

export type Validator = {
	Kind: string,
	Description: string,
	Check: CheckFn,
}

local DEFAULT_STRING_MAX = 256
local DEFAULT_ARRAY_MAX = 64
local DEFAULT_MAP_MAX = 32

local VALIDATOR_MARKER = newproxy(false)

local Validators = {}

local function make(kind: string, description: string, check: CheckFn): Validator
	return table.freeze({
		Kind = kind,
		Description = description,
		Check = check,
		[VALIDATOR_MARKER] = true,
	}) :: any
end

function Validators.isValidator(value: any): boolean
	return type(value) == "table" and rawget(value, VALIDATOR_MARKER) == true
end

local function assertValidator(value: any, where: string)
	if not Validators.isValidator(value) then
		error(`Validators: {where} must be a validator (build it with ACF.Validators)`, 3)
	end
end

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

local function got(value: any): string
	return `got {typeof(value)}`
end

-- Scalars ----------------------------------------------------------------------------

export type NumberOptions = { Min: number?, Max: number?, Integer: boolean? }

function Validators.number(options: NumberOptions?): Validator
	local opts: NumberOptions = options or {}
	local min, max, integer = opts.Min, opts.Max, opts.Integer == true
	return make("number", if integer then "integer" else "number", function(value, path)
		if type(value) ~= "number" then
			return false, `{path}: expected number, {got(value)}`
		end
		if not isFinite(value) then
			return false, `{path}: number must be finite`
		end
		if integer and value ~= math.floor(value) then
			return false, `{path}: expected an integer`
		end
		if min ~= nil and value < min then
			return false, `{path}: below minimum {min}`
		end
		if max ~= nil and value > max then
			return false, `{path}: above maximum {max}`
		end
		return true
	end)
end

function Validators.integer(options: { Min: number?, Max: number? }?): Validator
	local opts: { Min: number?, Max: number? } = options or {}
	return Validators.number({ Min = opts.Min, Max = opts.Max, Integer = true })
end

export type StringOptions = {
	MinLength: number?,
	MaxLength: number?,
	Pattern: string?,
	AllowInvalidUtf8: boolean?,
}

function Validators.string(options: StringOptions?): Validator
	local opts: StringOptions = options or {}
	local minLength = opts.MinLength or 0
	local maxLength = opts.MaxLength or DEFAULT_STRING_MAX
	local pattern = opts.Pattern
	local checkUtf8 = opts.AllowInvalidUtf8 ~= true
	return make("string", `string(<= {maxLength})`, function(value, path)
		if type(value) ~= "string" then
			return false, `{path}: expected string, {got(value)}`
		end
		local length = #value
		if length > maxLength then
			return false, `{path}: longer than {maxLength} bytes`
		end
		if length < minLength then
			return false, `{path}: shorter than {minLength} bytes`
		end
		if checkUtf8 and utf8.len(value) == nil then
			return false, `{path}: invalid UTF-8`
		end
		if pattern and not string.match(value, pattern) then
			return false, `{path}: does not match the required format`
		end
		return true
	end)
end

function Validators.boolean(): Validator
	return make("boolean", "boolean", function(value, path)
		if type(value) ~= "boolean" then
			return false, `{path}: expected boolean, {got(value)}`
		end
		return true
	end)
end

function Validators.literal(expected: any): Validator
	return make("literal", `literal {typeof(expected)}`, function(value, path)
		if value ~= expected then
			return false, `{path}: unexpected value`
		end
		return true
	end)
end

-- One of a fixed set of strings or numbers.
function Validators.enum(values: { any }): Validator
	if type(values) ~= "table" or #values == 0 then
		error("Validators.enum expects a non-empty array", 2)
	end
	local allowed = {}
	for _, v in values do
		allowed[v] = true
	end
	return make("enum", "enum", function(value, path)
		if (type(value) ~= "string" and type(value) ~= "number") or not allowed[value] then
			return false, `{path}: not an allowed value`
		end
		return true
	end)
end

-- Wrappers ---------------------------------------------------------------------------

function Validators.optional(inner: Validator): Validator
	assertValidator(inner, "optional(...)")
	return make("optional", `optional {inner.Description}`, function(value, path)
		if value == nil then
			return true
		end
		return inner.Check(value, path)
	end)
end

function Validators.union(...: Validator): Validator
	local options = { ... }
	if #options < 2 then
		error("Validators.union expects at least two validators", 2)
	end
	for i, v in options do
		assertValidator(v, `union argument {i}`)
	end
	return make("union", "union", function(value, path)
		for _, v in options do
			if v.Check(value, path) then
				return true
			end
		end
		return false, `{path}: matched none of the allowed types ({got(value)})`
	end)
end

-- Custom check. `fn(value)` returns true, or false plus an optional reason. Reasons are
-- written by the developer, so they are safe to log. Errors count as rejection.
function Validators.custom(name: string, fn: (value: any) -> (boolean, string?)): Validator
	if type(name) ~= "string" or type(fn) ~= "function" then
		error("Validators.custom expects (name, function)", 2)
	end
	return make("custom", name, function(value, path)
		local ok, passed, reason = pcall(fn, value)
		if not ok then
			return false, `{path}: {name} check errored`
		end
		if not passed then
			return false, `{path}: {reason or ("failed " .. name)}`
		end
		return true
	end)
end

-- Tables -----------------------------------------------------------------------------

-- Sequential array 1..n with every element matching `element`.
function Validators.array(element: Validator, options: { MinLength: number?, MaxLength: number? }?): Validator
	assertValidator(element, "array element")
	local opts: { MinLength: number?, MaxLength: number? } = options or {}
	local minLength = opts.MinLength or 0
	local maxLength = opts.MaxLength or DEFAULT_ARRAY_MAX
	return make("array", `array(<= {maxLength})`, function(value, path)
		if type(value) ~= "table" then
			return false, `{path}: expected array, {got(value)}`
		end
		local count = 0
		for key in value do
			count += 1
			if count > maxLength then
				return false, `{path}: more than {maxLength} items`
			end
			if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
				return false, `{path}: arrays may only have positive integer keys`
			end
		end
		if count < minLength then
			return false, `{path}: fewer than {minLength} items`
		end
		for i = 1, count do
			local item = value[i]
			if item == nil then
				return false, `{path}: array has holes`
			end
			local ok, err = element.Check(item, `{path}[{i}]`)
			if not ok then
				return false, err
			end
		end
		return true
	end)
end

-- Dictionary with known string keys. Unknown keys are rejected unless AllowExtra.
function Validators.struct(fields: { [string]: Validator }, options: { AllowExtra: boolean? }?): Validator
	if type(fields) ~= "table" then
		error("Validators.struct expects a table of field validators", 2)
	end
	local names = {}
	for name, v in fields do
		if type(name) ~= "string" then
			error("Validators.struct field names must be strings", 2)
		end
		assertValidator(v, `struct field '{name}'`)
		table.insert(names, name)
	end
	table.sort(names)
	local allowExtra = options ~= nil and options.AllowExtra == true
	local budget = #names + (if allowExtra then DEFAULT_MAP_MAX else 0)
	return make("struct", "struct", function(value, path)
		if type(value) ~= "table" then
			return false, `{path}: expected table, {got(value)}`
		end
		local count = 0
		for key in value do
			count += 1
			if count > budget then
				return false, `{path}: too many keys`
			end
			if type(key) ~= "string" then
				return false, `{path}: keys must be strings`
			end
			if not allowExtra and fields[key] == nil then
				return false, `{path}: unexpected key`
			end
		end
		for _, name in names do
			local ok, err = fields[name].Check(value[name], `{path}.{name}`)
			if not ok then
				return false, err
			end
		end
		return true
	end)
end

function Validators.map(key: Validator, valueValidator: Validator, options: { MaxEntries: number? }?): Validator
	assertValidator(key, "map key")
	assertValidator(valueValidator, "map value")
	local maxEntries = (options and options.MaxEntries) or DEFAULT_MAP_MAX
	return make("map", `map(<= {maxEntries})`, function(value, path)
		if type(value) ~= "table" then
			return false, `{path}: expected table, {got(value)}`
		end
		local count = 0
		for k, v in value do
			count += 1
			if count > maxEntries then
				return false, `{path}: more than {maxEntries} entries`
			end
			local ok, err = key.Check(k, `{path}<key>`)
			if not ok then
				return false, err
			end
			ok, err = valueValidator.Check(v, `{path}[{count}]`)
			if not ok then
				return false, err
			end
		end
		return true
	end)
end

-- Roblox types -----------------------------------------------------------------------

-- An Instance, optionally of a class and inside a root. `DescendantOf` may be an
-- Instance or a function(value) -> Instance? (e.g. resolve the player's plot).
function Validators.instance(className: string?, options: { DescendantOf: any? }?): Validator
	local root = options and options.DescendantOf
	return make("instance", className or "Instance", function(value, path)
		if typeof(value) ~= "Instance" then
			return false, `{path}: expected Instance, {got(value)}`
		end
		if className and not value:IsA(className) then
			return false, `{path}: expected {className}`
		end
		if root ~= nil then
			local container = if type(root) == "function" then root(value) else root
			if container == nil or not value:IsDescendantOf(container) then
				return false, `{path}: outside the allowed container`
			end
		end
		return true
	end)
end

function Validators.vector3(options: { MaxMagnitude: number? }?): Validator
	local maxMagnitude = options and options.MaxMagnitude
	return make("vector3", "Vector3", function(value, path)
		if typeof(value) ~= "Vector3" then
			return false, `{path}: expected Vector3, {got(value)}`
		end
		if not (isFinite(value.X) and isFinite(value.Y) and isFinite(value.Z)) then
			return false, `{path}: components must be finite`
		end
		if maxMagnitude and value.Magnitude > maxMagnitude then
			return false, `{path}: magnitude above {maxMagnitude}`
		end
		return true
	end)
end

function Validators.cframe(): Validator
	return make("cframe", "CFrame", function(value, path)
		if typeof(value) ~= "CFrame" then
			return false, `{path}: expected CFrame, {got(value)}`
		end
		for _, component in { value:GetComponents() } do
			if not isFinite(component) then
				return false, `{path}: components must be finite`
			end
		end
		return true
	end)
end

return table.freeze(Validators)
