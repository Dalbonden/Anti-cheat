--!strict
--[[
	Schema-validated configuration.

	The full configuration is described by a schema built from Configuration.Schema
	constructors. Load() resolves user overrides against the schema and collects every
	problem it finds (unknown keys with "did you mean" suggestions, wrong types, values
	out of range, invalid enum values) instead of stopping at the first one. Resolved
	values are deep-frozen: nothing can change configuration after load.

	"Open" nodes (used for ModuleSettings) accept arbitrary sub-keys at load time. Each
	sub-key is validated later, when the module that owns it registers its schema via
	Extend(). Keys never claimed by a module are reported by UnclaimedKeys(), so a typo
	in a module name still fails loudly at Start.
]]

export type SchemaKind = "number" | "boolean" | "string" | "enum" | "table" | "map" | "open"

export type SchemaNode = {
	Kind: SchemaKind,
	Default: any,
	Description: string?,
	Min: number?,
	Max: number?,
	Integer: boolean?,
	MaxLength: number?,
	Values: { string }?,
	Fields: { [string]: SchemaNode }?,
	ValueSchema: SchemaNode?,
}

local MAX_DEPTH = 16

local function deepClone(value: any, depth: number?): any
	local level = depth or 0
	if type(value) ~= "table" then
		return value
	end
	if level > MAX_DEPTH then
		error("Configuration: table nesting is too deep (cyclic table?)", 0)
	end
	local copy = {}
	for k, v in value do
		copy[k] = deepClone(v, level + 1)
	end
	return copy
end

local function deepFreeze(value: any): any
	if type(value) == "table" and not table.isfrozen(value) then
		for _, v in value do
			deepFreeze(v)
		end
		table.freeze(value)
	end
	return value
end

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function levenshtein(a: string, b: string): number
	local la, lb = #a, #b
	if la == 0 then
		return lb
	end
	if lb == 0 then
		return la
	end
	local prev = table.create(lb + 1, 0)
	for j = 0, lb do
		prev[j + 1] = j
	end
	for i = 1, la do
		local cur = table.create(lb + 1, 0)
		cur[1] = i
		local ca = string.byte(a, i)
		for j = 1, lb do
			local cost = if ca == string.byte(b, j) then 0 else 1
			cur[j + 1] = math.min(prev[j + 1] + 1, cur[j] + 1, prev[j] + cost)
		end
		prev = cur
	end
	return prev[lb + 1]
end

local function suggest(input: string, candidates: { string }): string?
	local lower = string.lower(input)
	local best, bestDistance = nil, math.huge
	for _, candidate in candidates do
		if string.lower(candidate) == lower then
			return candidate
		end
		local distance = levenshtein(lower, string.lower(candidate))
		if distance < bestDistance then
			best, bestDistance = candidate, distance
		end
	end
	if best and bestDistance <= math.max(1, math.floor(#input / 4)) then
		return best
	end
	return nil
end

local function describe(value: any): string
	if type(value) == "string" then
		return `'{value}'`
	end
	return `{typeof(value)} {tostring(value)}`
end

-- Schema constructors ----------------------------------------------------------------

local Schema = {}

local function check(condition: boolean, message: string)
	if not condition then
		error("Configuration schema: " .. message, 3)
	end
end

function Schema.Number(
	default: number,
	options: { Min: number?, Max: number?, Integer: boolean?, Description: string? }?
): SchemaNode
	local opts: { Min: number?, Max: number?, Integer: boolean?, Description: string? } = options or {}
	check(isFiniteNumber(default), "Number default must be a finite number")
	check(opts.Min == nil or default >= opts.Min, "Number default is below Min")
	check(opts.Max == nil or default <= opts.Max, "Number default is above Max")
	check(not opts.Integer or default == math.floor(default), "Number default must be an integer")
	return table.freeze({
		Kind = "number",
		Default = default,
		Min = opts.Min,
		Max = opts.Max,
		Integer = opts.Integer,
		Description = opts.Description,
	}) :: any
end

function Schema.Boolean(default: boolean, description: string?): SchemaNode
	check(type(default) == "boolean", "Boolean default must be a boolean")
	return table.freeze({ Kind = "boolean", Default = default, Description = description }) :: any
end

function Schema.String(default: string, options: { MaxLength: number?, Description: string? }?): SchemaNode
	local opts: { MaxLength: number?, Description: string? } = options or {}
	check(type(default) == "string", "String default must be a string")
	return table.freeze({
		Kind = "string",
		Default = default,
		MaxLength = opts.MaxLength,
		Description = opts.Description,
	}) :: any
end

function Schema.Enum(values: { string }, default: string, description: string?): SchemaNode
	check(type(values) == "table" and #values > 0, "Enum needs at least one value")
	check(table.find(values, default) ~= nil, "Enum default must be one of its values")
	return table.freeze({
		Kind = "enum",
		Values = table.freeze(table.clone(values)),
		Default = default,
		Description = description,
	}) :: any
end

function Schema.Table(fields: { [string]: SchemaNode }, description: string?): SchemaNode
	check(type(fields) == "table", "Table fields must be a table")
	for key, node in fields do
		check(type(key) == "string", "Table field names must be strings")
		check(type(node) == "table" and type(node.Kind) == "string", `Table field '{key}' is not a schema node`)
	end
	return table.freeze({
		Kind = "table",
		Fields = table.freeze(table.clone(fields)),
		Default = nil,
		Description = description,
	}) :: any
end

-- A string-keyed dictionary whose values all follow valueSchema. User entries are
-- merged over the defaults.
function Schema.Map(valueSchema: SchemaNode, default: { [string]: any }?, description: string?): SchemaNode
	check(type(valueSchema) == "table" and type(valueSchema.Kind) == "string", "Map value schema is not a schema node")
	return table.freeze({
		Kind = "map",
		ValueSchema = valueSchema,
		Default = table.freeze(table.clone(default or {})),
		Description = description,
	}) :: any
end

-- A table whose sub-keys are validated later via Configuration:Extend().
function Schema.Open(description: string?): SchemaNode
	return table.freeze({ Kind = "open", Default = nil, Description = description }) :: any
end

-- Resolution -------------------------------------------------------------------------

local resolve: (node: SchemaNode, value: any, path: string, errors: { string }) -> any

local function defaultOf(node: SchemaNode): any
	if node.Kind == "table" then
		local result = {}
		for key, field in node.Fields :: { [string]: SchemaNode } do
			result[key] = defaultOf(field)
		end
		return result
	elseif node.Kind == "map" then
		return deepClone(node.Default)
	elseif node.Kind == "open" then
		return {}
	end
	return node.Default
end

local function sortedKeys(dict: { [string]: any }): { string }
	local keys = {}
	for key in dict do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

resolve = function(node: SchemaNode, value: any, path: string, errors: { string }): any
	if value == nil then
		return defaultOf(node)
	end
	local kind = node.Kind
	if kind == "number" then
		if not isFiniteNumber(value) then
			table.insert(errors, `{path}: expected a finite number, got {describe(value)}`)
			return node.Default
		end
		if node.Integer and value ~= math.floor(value) then
			table.insert(errors, `{path}: expected an integer, got {value}`)
			return node.Default
		end
		if node.Min ~= nil and value < node.Min then
			table.insert(errors, `{path}: {value} is below the minimum of {node.Min}`)
			return node.Default
		end
		if node.Max ~= nil and value > node.Max then
			table.insert(errors, `{path}: {value} is above the maximum of {node.Max}`)
			return node.Default
		end
		return value
	elseif kind == "boolean" then
		if type(value) ~= "boolean" then
			table.insert(errors, `{path}: expected a boolean, got {describe(value)}`)
			return node.Default
		end
		return value
	elseif kind == "string" then
		if type(value) ~= "string" then
			table.insert(errors, `{path}: expected a string, got {describe(value)}`)
			return node.Default
		end
		if node.MaxLength and #value > node.MaxLength then
			table.insert(errors, `{path}: string is longer than {node.MaxLength} characters`)
			return node.Default
		end
		return value
	elseif kind == "enum" then
		local values = node.Values :: { string }
		if type(value) ~= "string" or table.find(values, value) == nil then
			local hint = if type(value) == "string" then suggest(value, values) else nil
			local message = `{path}: expected one of {table.concat(values, ", ")}, got {describe(value)}`
			if hint then
				message ..= ` (did you mean '{hint}'?)`
			end
			table.insert(errors, message)
			return node.Default
		end
		return value
	elseif kind == "table" then
		if type(value) ~= "table" then
			table.insert(errors, `{path}: expected a table, got {describe(value)}`)
			return defaultOf(node)
		end
		local fields = node.Fields :: { [string]: SchemaNode }
		local known = sortedKeys(fields)
		for key in value do
			if type(key) ~= "string" then
				table.insert(errors, `{path}: keys must be strings, got {describe(key)}`)
			elseif fields[key] == nil then
				local childPath = if path == "" then key else `{path}.{key}`
				local hint = suggest(key, known)
				local message = `{childPath}: unknown configuration key`
				if hint then
					message ..= ` (did you mean '{hint}'?)`
				end
				table.insert(errors, message)
			end
		end
		local result = {}
		for _, key in known do
			local childPath = if path == "" then key else `{path}.{key}`
			result[key] = resolve(fields[key], value[key], childPath, errors)
		end
		return result
	elseif kind == "map" then
		if type(value) ~= "table" then
			table.insert(errors, `{path}: expected a table, got {describe(value)}`)
			return defaultOf(node)
		end
		local result = defaultOf(node)
		for key, entry in value do
			if type(key) ~= "string" then
				table.insert(errors, `{path}: keys must be strings, got {describe(key)}`)
			else
				result[key] = resolve(node.ValueSchema :: SchemaNode, entry, `{path}.{key}`, errors)
			end
		end
		return result
	elseif kind == "open" then
		if type(value) ~= "table" then
			table.insert(errors, `{path}: expected a table, got {describe(value)}`)
			return {}
		end
		local result = {}
		for key, entry in value do
			if type(key) ~= "string" then
				table.insert(errors, `{path}: keys must be strings, got {describe(key)}`)
			else
				-- Snapshot now; validated when the owning module calls Extend().
				local ok, cloned = pcall(deepClone, entry)
				if ok then
					result[key] = cloned
				else
					table.insert(errors, `{path}.{key}: {cloned}`)
				end
			end
		end
		return result
	end
	error(`Configuration: unknown schema kind '{tostring(kind)}'`)
end

-- Configuration object ---------------------------------------------------------------

local Configuration = {}
Configuration.__index = Configuration
Configuration.Schema = table.freeze(Schema)

export type Configuration = typeof(setmetatable(
	{} :: {
		_schema: SchemaNode,
		_values: { [string]: any }?,
		-- open path -> raw user values awaiting Extend()
		_pending: { [string]: { [string]: any } },
		-- open path -> resolved, frozen sections
		_claimed: { [string]: { [string]: any } },
	},
	Configuration
))

function Configuration.new(schema: SchemaNode): Configuration
	assert(type(schema) == "table" and schema.Kind == "table", "Configuration root schema must be a Table")
	return setmetatable({ _schema = schema, _values = nil, _pending = {}, _claimed = {} }, Configuration)
end

local function findOpenNodes(node: SchemaNode, path: string, out: { string })
	if node.Kind == "open" then
		table.insert(out, path)
	elseif node.Kind == "table" then
		for key, field in node.Fields :: { [string]: SchemaNode } do
			findOpenNodes(field, if path == "" then key else `{path}.{key}`, out)
		end
	end
end

-- Validates overrides against the schema. Returns (true, {}) on success, or
-- (false, errors) without changing any state.
function Configuration.Load(self: Configuration, overrides: { [string]: any }?): (boolean, { string })
	if self._values ~= nil then
		error("Configuration has already been loaded", 2)
	end
	local errors = {}
	if overrides ~= nil and type(overrides) ~= "table" then
		return false, { `configuration must be a table, got {typeof(overrides)}` }
	end
	local resolved = resolve(self._schema, overrides or {}, "", errors)
	if #errors > 0 then
		return false, errors
	end

	local openPaths = {}
	findOpenNodes(self._schema, "", openPaths)
	for _, openPath in openPaths do
		local container = resolved
		local parts = string.split(openPath, ".")
		for i = 1, #parts - 1 do
			container = container[parts[i]]
		end
		local last = parts[#parts]
		self._pending[openPath] = container[last]
		self._claimed[openPath] = {}
		-- Replaced on read by the claimed sections (see Get).
		container[last] = nil
	end

	self._values = deepFreeze(resolved)
	return true, {}
end

function Configuration.IsLoaded(self: Configuration): boolean
	return self._values ~= nil
end

-- Validates the raw value at `openPath.key` against `schema` and makes it readable via
-- Get(). Must be called after Load(). A key may be claimed once.
function Configuration.Extend(self: Configuration, openPath: string, key: string, schema: SchemaNode): (boolean, { string })
	if self._values == nil then
		error("Configuration:Extend called before Load", 2)
	end
	local pending = self._pending[openPath]
	local claimed = self._claimed[openPath]
	if pending == nil or claimed == nil then
		error(`Configuration: '{openPath}' is not an open section`, 2)
	end
	if claimed[key] ~= nil then
		error(`Configuration: '{openPath}.{key}' has already been claimed`, 2)
	end
	if type(schema) ~= "table" or schema.Kind ~= "table" then
		error(`Configuration: schema for '{openPath}.{key}' must be a Schema.Table`, 2)
	end
	local errors = {}
	local value = resolve(schema, pending[key], `{openPath}.{key}`, errors)
	if #errors > 0 then
		return false, errors
	end
	claimed[key] = deepFreeze(value)
	pending[key] = nil
	return true, {}
end

-- Keys supplied under open sections that no module has claimed, as full paths.
function Configuration.UnclaimedKeys(self: Configuration): { string }
	local result = {}
	for openPath, pending in self._pending do
		for key in pending do
			table.insert(result, `{openPath}.{key}`)
		end
	end
	table.sort(result)
	return result
end

-- Reads a dotted path such as "Evidence.MaxRecordsPerPlayer". Returned tables are frozen.
function Configuration.Get(self: Configuration, path: string): any
	local values = self._values
	if values == nil then
		error("Configuration:Get called before Load", 2)
	end
	for openPath, claimed in self._claimed do
		if path == openPath then
			return table.freeze(table.clone(claimed))
		end
		local prefix = openPath .. "."
		if string.sub(path, 1, #prefix) == prefix then
			local rest = string.split(string.sub(path, #prefix + 1), ".")
			local current: any = claimed
			for _, part in rest do
				if type(current) ~= "table" then
					return nil
				end
				current = current[part]
			end
			return current
		end
	end
	local current: any = values
	for _, part in string.split(path, ".") do
		if type(current) ~= "table" then
			return nil
		end
		current = current[part]
	end
	return current
end

return Configuration
