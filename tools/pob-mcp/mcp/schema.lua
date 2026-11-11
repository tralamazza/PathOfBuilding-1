local json = require("mcp.json")

local M = {}

local function merge(target, source)
	if not source then
		return target
	end
	for key, value in pairs(source) do
		target[key] = value
	end
	return target
end

function M.object(properties, required, additionalProperties)
	local result = {
		type = "object",
		properties = properties or json.emptyObject(),
	}
	if required and #required > 0 then
		result.required = required
	end
	if additionalProperties ~= nil then
		result.additionalProperties = additionalProperties
	end
	return result
end

function M.anyObject(description)
	return {
		type = "object",
		description = description,
		additionalProperties = true,
	}
end

function M.array(items, description)
	if not items then
		items = json.emptyObject()
	end
	return merge({
		type = "array",
		items = items,
	}, description and { description = description } or nil)
end

function M.string(description, extra)
	return merge({
		type = "string",
		description = description,
	}, extra)
end

function M.boolean(description)
	return {
		type = "boolean",
		description = description,
	}
end

function M.integer(description, extra)
	return merge({
		type = "integer",
		description = description,
	}, extra)
end

function M.number(description, extra)
	return merge({
		type = "number",
		description = description,
	}, extra)
end

function M.enum(values, description)
	return {
		type = "string",
		description = description,
		enum = values,
	}
end

return M
