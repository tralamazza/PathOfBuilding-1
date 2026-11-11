local ffi = require("ffi")

pcall(ffi.cdef, [[
char *getcwd(char *buffer, unsigned long size);
]])

local function currentDirectory()
	local buffer = ffi.new("char[4096]")
	local result = ffi.C.getcwd(buffer, 4096)
	if result == nil then
		return nil
	end
	return ffi.string(buffer)
end

local function normalizePath(path)
	path = path:gsub("\\", "/")
	path = path:gsub("/+$", "")
	return path
end

local function dirname(path)
	return path:match("^(.*)[/\\][^/\\]*$") or "."
end

local function absolutePath(path)
	if path:match("^[/\\]") or path:match("^%a:[/\\]") then
		return normalizePath(path)
	end
	return normalizePath((currentDirectory() or ".") .. "/" .. path)
end

local source = debug.getinfo(1, "S").source
if source:sub(1, 1) == "@" then
	source = source:sub(2)
end
local scriptPath = absolutePath(source)
local here = dirname(scriptPath)
local root = os.getenv("POB_PATH") and absolutePath(os.getenv("POB_PATH")) or nil
if not root then
	root = here:match("^(.*)/tools/pob%-mcp$") or dirname(dirname(here))
end
local src = root .. "/src"
local runtime = root .. "/runtime"
local userPath = os.getenv("POB_MCP_USER_PATH") and absolutePath(os.getenv("POB_MCP_USER_PATH")) or normalizePath((os.getenv("HOME") or os.getenv("USERPROFILE") or root) .. "/.pob-mcp")

package.path = table.concat({
	here .. "/?.lua",
	here .. "/?/init.lua",
	runtime .. "/lua/?.lua",
	runtime .. "/lua/?/init.lua",
	package.path,
}, ";")

local options = {
	root = root,
	src = src,
	runtime = runtime,
	userPath = userPath,
}

local Engine = require("engine.init")
local registry = require("tools.init")
local protocol = require("mcp.protocol")
local stdio = require("mcp.stdio")

local server = protocol.new({
	tools = registry.defs,
	handlers = registry.handlers,
	getApi = function()
		return Engine.get(options)
	end,
	version = "0.1.0",
})

stdio.run(server)
