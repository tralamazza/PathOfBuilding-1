local json = require("mcp.json")
local util = require("engine.util")

local M = {}

local supportedVersions = {
	["2024-11-05"] = true,
	["2025-03-26"] = true,
	["2025-06-18"] = true,
}
local defaultVersion = "2024-11-05"

local instructions = table.concat({
	"Path of Building build calculator. The active build is mutated in place.",
	"Typical workflow: build_new, passives_search/passives_allocate, skills_search/skills_add_group, items_search_uniques or items_add_rare/items_add_raw, config_search/config_set, then calc_stats.",
	"Use build_export to get XML or a share code. Node ids are specific to the current tree version.",
	"Use build_snapshot and build_restore before trying alternatives.",
}, " ")

function M.new(options)
	local self = {
		tools = options.tools or {},
		handlers = options.handlers or {},
		getApi = options.getApi,
		version = options.version or "0.1.0",
		name = options.name or "pob-mcp",
	}
	return setmetatable(self, { __index = M })
end

function M:log(message)
	io.stderr:write("[pob-mcp] " .. tostring(message) .. "\n")
	io.stderr:flush()
end

function M:negotiate(version)
	if version and supportedVersions[version] then
		return version
	end
	return defaultVersion
end

function M:errorResponse(id, code, message)
	return {
		jsonrpc = "2.0",
		id = id,
		error = {
			code = code,
			message = message,
		},
	}
end

function M:resultResponse(id, result)
	return {
		jsonrpc = "2.0",
		id = id,
		result = result,
	}
end

function M:toolText(id, text, isError)
	return self:resultResponse(id, {
		content = {
			{
				type = "text",
				text = text,
			},
		},
		isError = isError == true,
	})
end

function M:handleInitialize(request)
	local params = request.params or {}
	local version = self:negotiate(params.protocolVersion)
	return self:resultResponse(request.id, {
		protocolVersion = version,
		capabilities = {
			tools = {
				listChanged = false,
			},
		},
		serverInfo = {
			name = self.name,
			version = self.version,
		},
		instructions = instructions,
	})
end

function M:handleToolsList(request)
	return self:resultResponse(request.id, {
		tools = self.tools,
	})
end

function M:handleToolsCall(request)
	local params = request.params or {}
	local name = params.name
	local handler = name and self.handlers[name]
	if not handler then
		return self:toolText(request.id, "Unknown tool '" .. tostring(name) .. "'", true)
	end
	local arguments = params.arguments or {}
	if type(arguments) ~= "table" then
		return self:toolText(request.id, "Tool arguments must be an object", true)
	end
	local ok, result = xpcall(function()
		return handler(arguments, { api = self.getApi })
	end, function(err)
		return debug.traceback(tostring(err), 2)
	end)
	if not ok then
		local message = util.summaryLine(result)
		self:log("tool '" .. tostring(name) .. "' failed: " .. tostring(result))
		return self:toolText(request.id, message, true)
	end
	if result == nil then
		result = json.emptyObject()
	end
	local encoded, encodeError = json.encode(result)
	if not encoded then
		self:log("failed to encode result for tool '" .. tostring(name) .. "': " .. tostring(encodeError))
		return self:toolText(request.id, "Failed to encode tool result", true)
	end
	return self:toolText(request.id, encoded, false)
end

function M:handle(request)
	if type(request) ~= "table" then
		return self:errorResponse(nil, -32600, "Invalid Request")
	end
	local id = request.id
	local method = request.method
	if type(method) ~= "string" then
		return self:errorResponse(id, -32600, "Invalid Request")
	end
	if id == nil then
		return nil
	end
	if method == "initialize" then
		return self:handleInitialize(request)
	elseif method == "ping" then
		return self:resultResponse(id, json.emptyObject())
	elseif method == "tools/list" then
		return self:handleToolsList(request)
	elseif method == "tools/call" then
		return self:handleToolsCall(request)
	end
	return self:errorResponse(id, -32601, "Method not found: " .. method)
end

return M
