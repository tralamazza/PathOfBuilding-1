local M = {}

M.runtimePath = nil

local ffi = require("ffi")

pcall(ffi.cdef, [[
unsigned long compressBound(unsigned long sourceLen);
int compress2(unsigned char *dest, unsigned long *destLen, const unsigned char *source, unsigned long sourceLen, int level);
int uncompress(unsigned char *dest, unsigned long *destLen, const unsigned char *source, unsigned long sourceLen);
]])

local zlib
local zlibError

local function loadZlib()
	if zlib or zlibError then
		return zlib
	end
	local attempts = { "z", "libz", "zlib1" }
	if M.runtimePath then
		attempts[#attempts + 1] = M.runtimePath .. "/zlib1"
		attempts[#attempts + 1] = M.runtimePath .. "/zlib1.dll"
	end
	for _, name in ipairs(attempts) do
		local ok, library = pcall(ffi.load, name)
		if ok then
			zlib = library
			return zlib
		end
	end
	zlibError = "Unable to load zlib"
	return nil
end

function M.setRuntimePath(path)
	M.runtimePath = path
end

local function getBase64()
	return require("base64")
end

function M.compress(data)
	local library = loadZlib()
	if not library then
		return nil, zlibError
	end
	local sourceLength = #data
	local bound = tonumber(library.compressBound(sourceLength))
	if not bound or bound <= 0 then
		return nil, "compressBound failed"
	end
	local buffer = ffi.new("unsigned char[?]", bound)
	local length = ffi.new("unsigned long[1]", bound)
	local result = library.compress2(buffer, length, ffi.cast("const unsigned char*", data), sourceLength, 9)
	if result ~= 0 then
		return nil, "compress2 failed with code " .. tostring(result)
	end
	return ffi.string(buffer, tonumber(length[0]))
end

function M.decompress(data)
	local library = loadZlib()
	if not library then
		return nil, zlibError
	end
	local outputLength = #data * 8 + 256
	for _ = 1, 12 do
		local buffer = ffi.new("unsigned char[?]", outputLength)
		local length = ffi.new("unsigned long[1]", outputLength)
		local result = library.uncompress(buffer, length, ffi.cast("const unsigned char*", data), #data)
		if result == 0 then
			return ffi.string(buffer, tonumber(length[0]))
		elseif result ~= -5 then
			return nil, "uncompress failed with code " .. tostring(result)
		end
		outputLength = outputLength * 4
	end
	return nil, "Unable to decompress build code"
end

function M.encodeBuildCode(xml)
	local compressed, err = M.compress(xml)
	if not compressed then
		return nil, err
	end
	local encoded = getBase64().encode(compressed)
	encoded = encoded:gsub("+", "-"):gsub("/", "_")
	return encoded
end

function M.decodeBuildCode(code)
	if type(code) ~= "string" then
		return nil, "Build code must be a string"
	end
	code = code:gsub("%s+", "")
	code = code:gsub("-", "+"):gsub("_", "/")
	local remainder = #code % 4
	if remainder > 0 then
		code = code .. string.rep("=", 4 - remainder)
	end
	local compressed, err = getBase64().decode(code)
	if not compressed or #compressed == 0 then
		return nil, err or "Invalid build code encoding"
	end
	return M.decompress(compressed)
end

return M
