local M = {}

local ffi = require("ffi")

pcall(ffi.cdef, [[
char *getcwd(char *buffer, unsigned long size);
int chdir(const char *path);
int _chdir(const char *path);
int mkdir(const char *path, unsigned int mode);
int _mkdir(const char *path);
]])

local function normalizePath(path)
	return (path:gsub("\\", "/"):gsub("/+$", ""))
end

local function changeDirectory(path)
	local ok, result = pcall(function()
		return ffi.C.chdir(path)
	end)
	if ok and result == 0 then
		return true
	end
	local loaded, library = pcall(ffi.load, "c")
	if loaded then
		local loadedCall, callResult = pcall(function()
			return library.chdir(path)
		end)
		if loadedCall and callResult == 0 then
			return true
		end
	end
	local loadedWin, winLibrary = pcall(ffi.load, "msvcrt")
	if loadedWin then
		local loadedCall, callResult = pcall(function()
			return winLibrary._chdir(path)
		end)
		if loadedCall and callResult == 0 then
			return true
		end
	end
	return false, "Unable to change directory to '" .. path .. "'"
end

local function ensureDirectory(path)
	if not path or path == "" then
		return
	end
	pcall(function()
		ffi.C.mkdir(path, 493)
	end)
	local loaded, library = pcall(ffi.load, "msvcrt")
	if loaded then
		pcall(function()
			library._mkdir(path)
		end)
	end
end

local function installUtf8Fallback()
	local available = pcall(require, "lua-utf8")
	if available then
		return
	end
	package.preload["lua-utf8"] = function()
		local utf8 = {}
		for key, value in pairs(string) do
			utf8[key] = value
		end
		if not utf8.reverse then
			utf8.reverse = function(text)
				return text:reverse()
			end
		end
		utf8.next = function(text, index)
			if type(text) ~= "string" or #text == 0 then
				return nil
			end
			index = index or 0
			if index < 0 then
				return math.max(1, #text + index)
			end
			if index >= #text then
				return nil
			end
			return index + 1
		end
		return utf8
	end
end

local function installLogging()
	local write = io.stderr.write
	print = function(...)
		local count = select("#", ...)
		local parts = {}
		for index = 1, count do
			parts[index] = tostring(select(index, ...))
		end
		write(io.stderr, table.concat(parts, "\t") .. "\n")
		io.stderr:flush()
	end
end

local function loadSource(path)
	local file, openError = io.open(path, "rb")
	if not file then
		error(openError or ("Unable to open '" .. path .. "'"), 0)
	end
	local text = file:read("*a")
	file:close()
	text = text:gsub("^#@[^\n]*\n", "", 1)
	local chunk, compileError = loadstring(text, path)
	if not chunk then
		error(compileError, 0)
	end
	return chunk
end

local function installLoader()
	dofile = function(path)
		return loadSource(path)()
	end
	LoadModule = function(name, ...)
		if not name:match("%.lua$") then
			name = name .. ".lua"
		end
		return loadSource(name)(...)
	end
	PLoadModule = function(name, ...)
		if not name:match("%.lua$") then
			name = name .. ".lua"
		end
		return PCall(loadSource(name), ...)
	end
end

function M.boot(options)
	options = options or {}
	local root = normalizePath(options.root or error("Missing PoB root path"))
	local src = normalizePath(options.src or (root .. "/src"))
	local runtime = normalizePath(options.runtime or (root .. "/runtime"))
	local userPath = normalizePath(options.userPath or (os.getenv("HOME") or os.getenv("USERPROFILE") or root) .. "/.pob-mcp")

	package.path = runtime .. "/lua/?.lua;" .. runtime .. "/lua/?/init.lua;" .. package.path

	installUtf8Fallback()
	installLogging()

	local changed, changeError = changeDirectory(src)
	if not changed then
		error(changeError, 0)
	end

	dofile("_SimpleGraphic.def.lua")

	GetScriptPath = function()
		return src
	end
	GetRuntimePath = function()
		return runtime
	end
	GetUserPath = function()
		return userPath
	end
	GetWorkDir = function()
		return src
	end
	GetVirtualScreenSize = function()
		return 1920, 1080
	end

	installLoader()

	local realRequire = require
	require = function(name)
		if name == "lcurl.safe" then
			return nil
		end
		return realRequire(name)
	end

	__callbackTable__ = {}
	function runCallback(name, ...)
		if __callbackTable__[name] then
			return __callbackTable__[name](...)
		elseif __mainObject__ and __mainObject__[name] then
			return __mainObject__[name](__mainObject__, ...)
		end
	end

	dofile("Launch.lua")
	__mainObject__.continuousIntegrationMode = true
	ensureDirectory(userPath)
	runCallback("OnInit")
	if __mainObject__.promptMsg then
		local message = __mainObject__.promptMsg
		__mainObject__.promptMsg = nil
		error(message, 0)
	end
	__mainObject__.main:ChangeUserPath(userPath .. "/", true)
	runCallback("OnFrame")
	if __mainObject__.promptMsg then
		local message = __mainObject__.promptMsg
		__mainObject__.promptMsg = nil
		error(message, 0)
	end

	local main = __mainObject__.main
	main.saveNewModCache = false
	local build = main.modes["BUILD"]
	if not build then
		error("PoB did not enter build mode", 0)
	end

	return {
		root = root,
		src = src,
		runtime = runtime,
		userPath = userPath,
		main = main,
		launch = __mainObject__,
		build = build,
		runCallback = runCallback,
		loadSource = loadSource,
	}
end

return M
