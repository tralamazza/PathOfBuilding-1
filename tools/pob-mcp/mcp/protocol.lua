local json = require("mcp.json")
local util = require("engine.util")

local M = {}

local supportedVersions = {
	["2024-11-05"] = true,
	["2025-03-26"] = true,
	["2025-06-18"] = true,
}
local defaultVersion = "2025-06-18"

local instructions = table.concat({
	"Path of Building build calculator. The active build is mutated in place.",
	"Typical workflow: build_new, passives_search/passives_allocate, skills_search/skills_add_group, items_search_uniques or items_add_rare/items_add_raw, config_search/config_set, then calc_stats.",
	"Use calc_what_if for safe comparisons. Use build_set_constraints and build_validate to enforce level, budget, and item rules. Use build_export to get XML or a share code. Node ids are specific to the current tree version.",
	"Use build_snapshot and build_restore before trying alternatives.",
}, " ")

local function validId(id)
	return type(id) == "string" or (type(id) == "number" and id == id and id ~= math.huge and id ~= -math.huge)
end

local function schemaTypeError(path, expected, actual)
	return path .. " must be " .. expected .. ", got " .. actual
end

local function validateSchema(value, schema, path)
	if type(schema) ~= "table" then
		return nil
	end
	path = path or "$"
	local expected = schema.type
	if expected == "object" then
		if not json.isObject(value) then
			return schemaTypeError(path, "an object", type(value))
		end
		for _, key in ipairs(schema.required or {}) do
			if value[key] == nil then
				return path .. "." .. key .. " is required"
			end
		end
		local properties = schema.properties or {}
		for key, propertySchema in pairs(properties) do
			if value[key] ~= nil then
				local err = validateSchema(value[key], propertySchema, path .. "." .. key)
				if err then
					return err
				end
			end
		end
		if schema.additionalProperties == false then
			for key in pairs(value) do
				if not properties[key] then
					return path .. " has unknown property '" .. tostring(key) .. "'"
				end
			end
		end
	elseif expected == "array" then
		if not json.isArray(value) then
			return schemaTypeError(path, "an array", type(value))
		end
		for index, entry in ipairs(value) do
			local err = validateSchema(entry, schema.items, path .. "[" .. index .. "]")
			if err then
				return err
			end
		end
	elseif expected == "string" then
		if type(value) ~= "string" then
			return schemaTypeError(path, "a string", type(value))
		end
		if schema.enum then
			local matched = false
			for _, option in ipairs(schema.enum) do
				if value == option then
					matched = true
					break
				end
			end
			if not matched then
				return path .. " must be one of: " .. table.concat(schema.enum, ", ")
			end
		end
	elseif expected == "boolean" then
		if type(value) ~= "boolean" then
			return schemaTypeError(path, "a boolean", type(value))
		end
	elseif expected == "integer" or expected == "number" then
		if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
			return schemaTypeError(path, "a finite number", type(value))
		end
		if expected == "integer" and value % 1 ~= 0 then
			return path .. " must be an integer"
		end
		if schema.minimum and value < schema.minimum then
			return path .. " must be >= " .. tostring(schema.minimum)
		end
		if schema.maximum and value > schema.maximum then
			return path .. " must be <= " .. tostring(schema.maximum)
		end
	end
	return nil
end

function M.new(options)
	options = options or {}
	local definitions = {}
	for _, definition in ipairs(options.tools or {}) do
		definitions[definition.name] = definition
	end
	local self = {
		tools = options.tools or {},
		toolDefinitions = definitions,
		handlers = options.handlers or {},
		getApi = options.getApi,
		version = options.version or "0.1.0",
		name = options.name or "pob-mcp",
		initializeReceived = false,
		initialized = false,
		negotiatedVersion = nil,
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

function M:batchAllowed()
	return self.negotiatedVersion ~= "2025-06-18"
end

function M:errorResponse(id, code, message)
	return {
		jsonrpc = "2.0",
		id = id == nil and json.null or id,
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
	if self.initializeReceived then
		return self:errorResponse(request.id, -32600, "Server is already initialized")
	end
	local params = request.params
	if not json.isObject(params) then
		return self:errorResponse(request.id, -32602, "initialize params must be an object")
	end
	if type(params.protocolVersion) ~= "string" then
		return self:errorResponse(request.id, -32602, "initialize.protocolVersion is required")
	end
	if not json.isObject(params.capabilities) then
		return self:errorResponse(request.id, -32602, "initialize.capabilities must be an object")
	end
	if not json.isObject(params.clientInfo) or type(params.clientInfo.name) ~= "string" or type(params.clientInfo.version) ~= "string" then
		return self:errorResponse(request.id, -32602, "initialize.clientInfo.name and version are required")
	end
	self.initializeReceived = true
	self.negotiatedVersion = self:negotiate(params.protocolVersion)
	return self:resultResponse(request.id, {
		protocolVersion = self.negotiatedVersion,
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
	local params = request.params
	if not json.isObject(params) then
		return self:errorResponse(request.id, -32602, "tools/call params must be an object")
	end
	if type(params.name) ~= "string" then
		return self:errorResponse(request.id, -32602, "tools/call.name must be a string")
	end
	local handler = self.handlers[params.name]
	if not handler then
		return self:errorResponse(request.id, -32602, "Unknown tool '" .. params.name .. "'")
	end
	local arguments = params.arguments
	if arguments == nil then
		arguments = json.emptyObject()
	end
	if not json.isObject(arguments) then
		return self:errorResponse(request.id, -32602, "tools/call.arguments must be an object")
	end
	local definition = self.toolDefinitions[params.name]
	local validationError = validateSchema(arguments, definition and definition.inputSchema, "$")
	if validationError then
		return self:errorResponse(request.id, -32602, validationError)
	end
	local ok, result = xpcall(function()
		return handler(arguments, { api = self.getApi })
	end, function(err)
		return debug.traceback(tostring(err), 2)
	end)
	if not ok then
		local message = util.summaryLine(result)
		self:log("tool '" .. params.name .. "' failed: " .. tostring(result))
		return self:toolText(request.id, message, true)
	end
	if result == nil then
		result = json.emptyObject()
	end
	local encoded, encodeError = json.encode(result)
	if not encoded then
		self:log("failed to encode result for tool '" .. params.name .. "': " .. tostring(encodeError))
		return self:toolText(request.id, "Failed to encode tool result", true)
	end
	return self:toolText(request.id, encoded, false)
end

function M:handle(request)
	if type(request) ~= "table" or request == json.null then
		return self:errorResponse(nil, -32600, "Invalid Request")
	end
	local id = request.id
	local responseId = validId(id) and id or nil
	if type(request.method) ~= "string" then
		if id == nil then
			return nil
		end
		return self:errorResponse(responseId, -32600, "Invalid Request")
	end
	if request.jsonrpc ~= "2.0" then
		if id == nil then
			return nil
		end
		return self:errorResponse(responseId, -32600, "Invalid Request")
	end
	if id == json.null then
		return self:errorResponse(nil, -32600, "Invalid Request")
	end
	if id ~= nil and not validId(id) then
		return self:errorResponse(nil, -32600, "Invalid Request")
	end
	if id == nil then
		if request.method == "notifications/initialized" and self.initializeReceived then
			self.initialized = true
		end
		return nil
	end
	if request.params ~= nil and not json.isObject(request.params) then
		return self:errorResponse(id, -32602, "Invalid method parameters")
	end
	if request.method == "initialize" then
		return self:handleInitialize(request)
	end
	if not self.initializeReceived then
		return self:errorResponse(id, -32600, "Server has not been initialized")
	end
	if request.method == "ping" then
		return self:resultResponse(id, json.emptyObject())
	elseif request.method == "tools/list" then
		return self:handleToolsList(request)
	elseif request.method == "tools/call" then
		return self:handleToolsCall(request)
	end
	return self:errorResponse(id, -32601, "Method not found: " .. request.method)
end

return M
