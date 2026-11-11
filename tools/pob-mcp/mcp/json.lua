local dkjson = require("dkjson")

local M = {}

M.null = dkjson.null

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

function M.isObject(value)
	if type(value) ~= "table" or value == M.null then
		return false
	end
	local metadata = getmetatable(value)
	if metadata and metadata.__jsontype then
		return metadata.__jsontype == "object"
	end
	for key in pairs(value) do
		if type(key) == "string" then
			return true
		end
	end
	return next(value) == nil
end

function M.isArray(value)
	if type(value) ~= "table" or value == M.null then
		return false
	end
	local metadata = getmetatable(value)
	if metadata and metadata.__jsontype then
		return metadata.__jsontype == "array"
	end
	if not M.isObject(value) then
		return false
	end
	local count = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			return false
		end
		count = count + 1
	end
	return count > 0
end

local function validateSyntax(text)
	local inString = false
	local escaped = false
	for index = 1, #text do
		local char = text:sub(index, index)
		if inString then
			if escaped then
				escaped = false
			elseif char == "\\" then
				escaped = true
			elseif char == '"' then
				inString = false
			end
		else
			if char == '"' then
				inString = true
			elseif char == "/" then
				return false, "Comments are not valid JSON"
			elseif char == "," then
				local nextIndex = index + 1
				while text:sub(nextIndex, nextIndex):match("%s") do
					nextIndex = nextIndex + 1
				end
				local nextChar = text:sub(nextIndex, nextIndex)
				if nextChar == "}" or nextChar == "]" then
					return false, "Trailing comma in JSON"
				end
			end
		end
	end
	if inString then
		return false, "Unterminated JSON string"
	end
	return true
end

function M.encode(value)
	local ok, encoded = pcall(dkjson.encode, value, { indent = false })
	if not ok then
		return nil, tostring(encoded)
	end
	return encoded
end

function M.decode(text)
	local valid, syntaxError = validateSyntax(text)
	if not valid then
		return nil, syntaxError
	end
	local ok, value, position, err = pcall(dkjson.decode, text, 1, M.null)
	if not ok then
		return nil, tostring(value)
	end
	if err then
		return nil, err
	end
	local trailing = text:sub(position or #text + 1)
	if trailing:match("%S") then
		return nil, "Trailing characters after JSON value"
	end
	return value
end

return M
