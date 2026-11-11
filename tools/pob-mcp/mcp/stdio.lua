local json = require("mcp.json")
local util = require("engine.util")

local M = {}

local function writeResponse(server, response)
	local encoded, err = json.encode(response)
	if not encoded then
		server:log("failed to encode protocol response: " .. tostring(err))
		return
	end
	io.stdout:write(encoded, "\n")
	io.stdout:flush()
end

local function handleDecoded(server, decoded)
	if type(decoded) ~= "table" then
		local response = server:errorResponse(nil, -32600, "Invalid Request")
		writeResponse(server, response)
		return
	end
	if util.isArray(decoded) then
		if #decoded == 0 then
			writeResponse(server, server:errorResponse(nil, -32600, "Invalid Request"))
			return
		end
		local responses = {}
		for _, request in ipairs(decoded) do
			local response = server:handle(request)
			if response then
				responses[#responses + 1] = response
			end
		end
		if #responses > 0 then
			writeResponse(server, responses)
		end
		return
	end
	local response = server:handle(decoded)
	if response then
		writeResponse(server, response)
	end
end

function M.run(server)
	server:log("listening on stdio")
	while true do
		local line = io.read("*l")
		if not line then
			break
		end
		line = line:gsub("\r$", "")
		if line:match("%S") then
			local decoded, err = json.decode(line)
			if not decoded then
				writeResponse(server, server:errorResponse(nil, -32700, "Parse error: " .. tostring(err)))
			else
				handleDecoded(server, decoded)
			end
		end
	end
	server:log("stdin closed")
end

return M
