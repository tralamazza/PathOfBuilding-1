local M = {}

local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function M.stripColors(text)
	if type(text) ~= "string" then
		return text
	end
	text = text:gsub("%^x%x%x%x%x%x%x", "")
	text = text:gsub("%^%d", "")
	return text
end

function M.trim(text)
	if type(text) ~= "string" then
		return text
	end
	return text:match("^%s*(.-)%s*$")
end

function M.lower(text)
	return type(text) == "string" and text:lower() or text
end

function M.clamp(value, minimum, maximum)
	if value < minimum then
		return minimum
	elseif value > maximum then
		return maximum
	end
	return value
end

function M.isArray(value)
	if type(value) ~= "table" then
		return false
	end
	local count = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			return false
		end
		count = count + 1
	end
	for index = 1, count do
		if value[index] == nil then
			return false
		end
	end
	return true
end

local function sanitizeValue(value, state, depth)
	local valueType = type(value)
	if valueType == "string" then
		return state.strip and M.stripColors(value) or value
	elseif valueType == "number" then
		if not isFiniteNumber(value) then
			if value ~= value then
				return "nan"
			end
			return value > 0 and "inf" or "-inf"
		end
		return value
	elseif valueType == "boolean" or valueType == "nil" then
		return value
	elseif valueType ~= "table" then
		return tostring(value)
	end
	if depth >= state.depth then
		return nil
	end
	if state.seen[value] then
		return nil
	end
	state.seen[value] = true
	local metadata = getmetatable(value)
	local declaredType = metadata and metadata.__jsontype
	local output
	if M.isArray(value) then
		output = {}
		local maximum = math.min(#value, state.maxArray)
		for index = 1, maximum do
			output[index] = sanitizeValue(value[index], state, depth + 1)
		end
		if #value > maximum then
			output[#output + 1] = "<truncated>"
		end
	else
		output = {}
		local maximum = state.maxKeys
		local count = 0
		for key, entry in pairs(value) do
			if count >= maximum then
				output.__truncated = true
				break
			end
			local outputKey = type(key) == "string" and key or tostring(key)
			output[outputKey] = sanitizeValue(entry, state, depth + 1)
			count = count + 1
		end
	end
	if declaredType then
		setmetatable(output, { __jsontype = declaredType })
	end
	state.seen[value] = nil
	return output
end

function M.sanitize(value, options)
	options = options or {}
	local state = {
		depth = options.depth or 6,
		maxArray = options.maxArray or 2000,
		maxKeys = options.maxKeys or 500,
		strip = options.strip ~= false,
		seen = {},
	}
	return sanitizeValue(value, state, 0)
end

function M.arrayMap(values, mapper)
	local output = {}
	for index, value in ipairs(values) do
		output[index] = mapper(value, index)
	end
	return output
end

function M.sortedPairsKeys(tableValue)
	local keys = {}
	for key in pairs(tableValue) do
		keys[#keys + 1] = key
	end
	table.sort(keys, function(a, b)
		if type(a) == type(b) then
			return a < b
		end
		return tostring(a) < tostring(b)
	end)
	return keys
end

function M.joinLines(lines, prefix)
	local output = {}
	for index, line in ipairs(lines or {}) do
		output[index] = (prefix or "") .. tostring(line)
	end
	return table.concat(output, "\n")
end

function M.matchAny(text, patterns)
	text = M.lower(text)
	for _, pattern in ipairs(patterns or {}) do
		if pattern and pattern ~= "" and text:find(pattern, 1, true) then
			return true
		end
	end
	return false
end

function M.errorMessage(err)
	local message = tostring(err)
	message = M.stripColors(message)
	return message
end

function M.summaryLine(err)
	local message = M.errorMessage(err)
	message = message:gsub("\nstack traceback:.*$", "")
	message = message:gsub("^%s*Error:%s*", "")
	message = message:gsub("\nv[%d%.]+[^\n]*", "")
	message = message:gsub("\nPress Enter/Escape.*$", "")
	message = M.trim(message)
	local firstLine = message:match("^[^\n]+") or message
	return firstLine
end

return M
