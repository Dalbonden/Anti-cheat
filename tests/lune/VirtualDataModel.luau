--[[
	Lune-only: builds a virtual Roblox instance tree from a Rojo project file and
	implements script-relative `require(instance)`, so ACF's unmodified source runs
	outside Roblox.

	Supported: $className, $path (directories, init.luau, *.luau, *.server.luau,
	*.client.luau), nested tree nodes. Nodes expose Name, ClassName, Parent,
	FindFirstChild, WaitForChild, GetChildren, GetDescendants, GetFullName, IsA and
	child access by indexing. The DataModel node supports GetService for services that
	exist in the tree.

	This is a test harness, not a Roblox emulator: there is no physics, replication or
	real Players service. Anything platform-specific is supplied by fakes through
	ACF's Environment.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local task = require("@lune/task")

local VirtualDataModel = {}

local Node = {}
local NodeMethods = {}

local function newNode(name: string, className: string, parent: any?)
	local node = setmetatable({
		Name = name,
		ClassName = className,
		Parent = parent,
		_children = {},
		_order = {},
		_source = nil,
		_sourcePath = nil,
	}, Node)
	if parent then
		rawget(parent, "_children")[name] = node
		table.insert(rawget(parent, "_order"), node)
	end
	return node
end

Node.__index = function(self, key)
	local method = NodeMethods[key]
	if method then
		return method
	end
	local child = rawget(self, "_children")[key]
	if child then
		return child
	end
	error(`{key} is not a valid member of {rawget(self, "ClassName")} "{NodeMethods.GetFullName(self)}"`, 2)
end

Node.__tostring = function(self)
	return rawget(self, "Name")
end

function NodeMethods.FindFirstChild(self, name: string)
	return rawget(self, "_children")[name]
end

function NodeMethods.WaitForChild(self, name: string)
	local child = rawget(self, "_children")[name]
	if child == nil then
		error(`WaitForChild: '{name}' does not exist under '{NodeMethods.GetFullName(self)}' (virtual tree never yields)`, 2)
	end
	return child
end

function NodeMethods.GetChildren(self)
	return table.clone(rawget(self, "_order"))
end

function NodeMethods.GetDescendants(self)
	local result = {}
	local function walk(node)
		for _, child in rawget(node, "_order") do
			table.insert(result, child)
			walk(child)
		end
	end
	walk(self)
	return result
end

function NodeMethods.IsA(self, className: string)
	local mine = rawget(self, "ClassName")
	if mine == className then
		return true
	end
	if className == "LuaSourceContainer" then
		return mine == "ModuleScript" or mine == "Script" or mine == "LocalScript"
	end
	return className == "Instance"
end

function NodeMethods.GetFullName(self)
	local parts = {}
	local node = self
	while node ~= nil and rawget(node, "ClassName") ~= "DataModel" do
		table.insert(parts, 1, rawget(node, "Name"))
		node = rawget(node, "Parent")
	end
	return table.concat(parts, ".")
end

function NodeMethods.GetService(self, name: string)
	local child = rawget(self, "_children")[name]
	if child == nil then
		error(`GetService: service '{name}' is not available in the virtual DataModel`, 2)
	end
	return child
end

local SCRIPT_SUFFIXES = {
	{ ".server.luau", "Script" },
	{ ".client.luau", "LocalScript" },
	{ ".luau", "ModuleScript" },
	{ ".server.lua", "Script" },
	{ ".client.lua", "LocalScript" },
	{ ".lua", "ModuleScript" },
}

local function classifyFile(fileName: string): (string?, string?)
	for _, pair in SCRIPT_SUFFIXES do
		local suffix, className = pair[1], pair[2]
		if string.sub(fileName, -#suffix) == suffix then
			return string.sub(fileName, 1, #fileName - #suffix), className
		end
	end
	return nil, nil
end

local function joinPath(a: string, b: string): string
	return a .. "/" .. b
end

local function mountPath(path: string, name: string, parent: any)
	if fs.isFile(path) then
		local _, className = classifyFile(path)
		local node = newNode(name, className or "StringValue", parent)
		rawset(node, "_source", fs.readFile(path))
		rawset(node, "_sourcePath", path)
		return node
	end
	if not fs.isDir(path) then
		error(`VirtualDataModel: path '{path}' does not exist`)
	end
	local entries = fs.readDir(path)
	table.sort(entries)
	local initFile, initClass = nil, nil
	for _, entry in entries do
		local base, className = classifyFile(entry)
		if base == "init" then
			initFile, initClass = joinPath(path, entry), className
		end
	end
	local node = newNode(name, initClass or "Folder", parent)
	if initFile then
		rawset(node, "_source", fs.readFile(initFile))
		rawset(node, "_sourcePath", initFile)
	end
	for _, entry in entries do
		local full = joinPath(path, entry)
		if fs.isDir(full) then
			mountPath(full, entry, node)
		else
			local base, className = classifyFile(entry)
			if base and base ~= "init" and className then
				local child = newNode(base, className, node)
				rawset(child, "_source", fs.readFile(full))
				rawset(child, "_sourcePath", full)
			end
		end
	end
	return node
end

local function buildTree(definition: { [string]: any }, name: string, parent: any?, root: string)
	local node
	if definition["$path"] then
		node = mountPath(joinPath(root, definition["$path"]), name, parent)
	else
		node = newNode(name, definition["$className"] or "Folder", parent)
	end
	for key, value in definition do
		if string.sub(key, 1, 1) ~= "$" and type(value) == "table" then
			buildTree(value, key, node, root)
		end
	end
	return node
end

-- Loads a Rojo project. Returns `game` (the DataModel node) and a `require` that
-- executes ModuleScript nodes with Roblox-style globals.
function VirtualDataModel.load(projectFile: string, root: string)
	local project = serde.decode("json", fs.readFile(projectFile))
	local game = buildTree(project.tree, "Game", nil, root)
	rawset(game, "ClassName", "DataModel")

	local cache = {}
	local loading = {}

	local requireNode
	requireNode = function(node)
		if type(node) ~= "table" or getmetatable(node) ~= Node then
			error("require expects a ModuleScript instance (virtual tree)", 2)
		end
		if rawget(node, "ClassName") ~= "ModuleScript" then
			error(`require: '{NodeMethods.GetFullName(node)}' is a {rawget(node, "ClassName")}, not a ModuleScript`, 2)
		end
		local cached = cache[node]
		if cached ~= nil then
			return cached.value
		end
		if loading[node] then
			error(`require: cyclic dependency involving '{NodeMethods.GetFullName(node)}'`, 2)
		end
		loading[node] = true
		local chunk = luau.load(rawget(node, "_source"), {
			debugName = rawget(node, "_sourcePath") or NodeMethods.GetFullName(node),
			environment = {
				script = node,
				require = requireNode,
				game = game,
				task = task,
			},
		})
		local results = table.pack(chunk())
		loading[node] = nil
		if results.n ~= 1 then
			error(`Module '{NodeMethods.GetFullName(node)}' must return exactly one value, returned {results.n}`, 2)
		end
		cache[node] = { value = results[1] }
		return results[1]
	end

	return game, requireNode
end

return VirtualDataModel
