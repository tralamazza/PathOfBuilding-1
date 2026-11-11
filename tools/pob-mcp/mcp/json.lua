local dkjson = require("dkjson")

local M = {}

function M.emptyObject()
	return setmetatable({}, { __jsontype = "object" })
end

function M.emptyArray()
	return setmetatable({}, { __jsontype = "array" })
end

function M.object(value)
	if type(value) == "table" then
		setmetatable(value, { __jsontype = "object" })
	end
	return value
end

function M.encode(value)
	local ok, encoded = pcall(dkjson.encode, value, { indent = false })
	if not ok then
		return nil, tostring(encoded)
	end
	return encoded
end

function M.decode(text)
	local ok, value, position, err = pcall(dkjson.decode, text, 1, nil)
	if not ok then
		return nil, tostring(value)
	end
	if err then
		return nil, err
	end
	return value, position
end

return M
