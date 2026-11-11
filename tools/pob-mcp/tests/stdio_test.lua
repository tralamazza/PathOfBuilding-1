local ffi = require("ffi")

pcall(ffi.cdef, [[
char *getcwd(char *buffer, unsigned long size);
]])

local function normalizePath(path)
	return (path:gsub("\\", "/"):gsub("/+$", ""))
end

local function dirname(path)
	return path:match("^(.*)[/\\][^/\\]*$") or "."
end

local function absolutePath(path)
	if path:match("^[/\\]") or path:match("^%a:[/\\]") then
		return normalizePath(path)
	end
	local buffer = ffi.new("char[4096]")
	local cwd = ffi.C.getcwd(buffer, 4096)
	return normalizePath(ffi.string(cwd) .. "/" .. path)
end

local source = debug.getinfo(1, "S").source
if source:sub(1, 1) == "@" then
	source = source:sub(2)
end
local testDir = dirname(absolutePath(source))
local toolRoot = dirname(testDir)
local root = dirname(dirname(toolRoot))
local runtime = root .. "/runtime"

package.path = toolRoot .. "/?.lua;" .. toolRoot .. "/?/init.lua;" .. runtime .. "/lua/?.lua;" .. runtime .. "/lua/?/init.lua;" .. package.path
local json = require("mcp.json")

local luajit = os.getenv("POB_MCP_LUAJIT") or "luajit"
local mainScript = toolRoot .. "/main.lua"
local userPath = os.getenv("POB_MCP_USER_PATH") or (os.tmpname() .. ".pob-mcp")

local function shellQuote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function writeRequests(path, messages)
	local file = assert(io.open(path, "wb"))
	for _, message in ipairs(messages) do
		file:write(message, "\n")
	end
	file:close()
end

local function runServer(requests, label)
	local requestPath = os.tmpname()
	local outputPath = os.tmpname()
	local errorPath = os.tmpname()
	writeRequests(requestPath, requests)
	local command = table.concat({
		"POB_MCP_USER_PATH=" .. shellQuote(userPath),
		shellQuote(luajit),
		shellQuote(mainScript),
		"< " .. shellQuote(requestPath),
		"> " .. shellQuote(outputPath),
		"2> " .. shellQuote(errorPath),
	}, " ")
	local status = os.execute(command)
	local responses = {}
	local responseList = {}
	local function addResponse(decoded)
		responseList[#responseList + 1] = decoded
		if type(decoded.id) == "string" or type(decoded.id) == "number" then
			responses[tostring(decoded.id)] = decoded
		end
	end
	local output = assert(io.open(outputPath, "rb"))
	for line in output:lines() do
		if line:match("%S") then
			local decoded, err = json.decode(line)
			assert(decoded ~= nil, "invalid JSON response in " .. label .. ": " .. tostring(err) .. "\n" .. line)
			if json.isArray(decoded) then
				for _, entry in ipairs(decoded) do
					addResponse(entry)
				end
			else
				addResponse(decoded)
			end
		end
	end
	output:close()
	local errorFile = io.open(errorPath, "rb")
	local stderr = errorFile and errorFile:read("*a") or ""
	if errorFile then
		errorFile:close()
	end
	os.remove(requestPath)
	os.remove(outputPath)
	os.remove(errorPath)
	assert(status == true or status == 0, "server failed for " .. label .. "\n" .. stderr)
	return responses, responseList, stderr
end

local function toolResult(response, label)
	assert(response, "missing response for " .. label)
	assert(response.result, "missing tool result for " .. label)
	local content = response.result.content
	assert(content and content[1] and content[1].text, "missing tool content for " .. label)
	if response.result.isError then
		return content[1].text, true
	end
	local decoded, err = json.decode(content[1].text)
	assert(decoded, "invalid tool JSON for " .. label .. ": " .. tostring(err))
	return decoded, false
end

local initialize = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"pob-mcp-test","version":"1"}}}'
local initialized = '{"jsonrpc":"2.0","method":"notifications/initialized"}'

local requests = {
	initialize,
	initialized,
	'{"jsonrpc":"2.0","id":2,"method":"tools/list"}',
	'{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"build_new","arguments":{"class":"Witch","ascendancy":"Occultist","level":90}}}',
	'{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"skills_add_group","arguments":{"gems":[{"name":"Fireball","level":20,"quality":20},{"name":"Controlled Destruction","level":20,"quality":20}]}}}',
	'{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"calc_stats","arguments":{"stats":["TotalDPS","Life"]}}}',
	'{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"passives_search","arguments":{"query":"Deep Wisdom"}}}',
	'{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"passives_allocate","arguments":{"names":["Deep Wisdom"]}}}',
	'{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"items_search_uniques","arguments":{"query":"Abyssus"}}}',
	'{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"items_add_unique","arguments":{"name":"Abyssus"}}}',
	'{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"build_export","arguments":{"format":"code"}}}',
	'{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"config_search","arguments":{"query":"onslaught"}}}',
	'{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"missing_tool","arguments":{}}}',
	'{"jsonrpc":"2.0","id":13,"method":"unknown/method"}',
	'{"jsonrpc":"2.0","id":14,"method":"ping"}',
	'{"jsonrpc":"2.0","id":15,"method":"tools/call","params":1}',
	'{"jsonrpc":"2.0","id":16,"method":"tools/call","params":{"name":"build_new","arguments":{"level":200}}}',
	'{"jsonrpc":"2.0","id":17,"method":"tools/call","params":{"name":"build_new","arguments":false}}',
	'{"jsonrpc":"2.0","id":18,"method":"ping"} trailing',
	'{"jsonrpc":"2.0","id":19,"method":"ping",}',
	'false',
	'null',
	'[null,{"jsonrpc":"2.0","id":20,"method":"ping"}]',
	'not valid json',
}

local responses, responseList, stderr = runServer(requests, "first session")

assert(responses["1"].result.protocolVersion == "2024-11-05", "unexpected protocol version")
local tools = responses["2"].result.tools
local toolNames = {}
for _, tool in ipairs(tools) do
	toolNames[tool.name] = true
end
assert(toolNames.build_new and toolNames.passives_allocate and toolNames.calc_stats, "missing tools")

local newBuild, newBuildError = toolResult(responses["3"], "build_new")
assert(not newBuildError, "build_new failed")
assert(newBuild.class == "Witch", "wrong class")
assert(newBuild.level == 90, "wrong level")

local skillGroup, skillError = toolResult(responses["4"], "skills_add_group")
assert(not skillError, "skills_add_group failed")
assert(skillGroup.group_index == 1, "wrong skill group index")

local stats, statsError = toolResult(responses["5"], "calc_stats")
assert(not statsError, "calc_stats failed")
assert(stats.main_skill.name == "Fireball", "wrong main skill")
assert(stats.requested.TotalDPS > 0, "expected positive DPS")
local exported, exportError = toolResult(responses["10"], "build_export")
assert(not exportError, "build_export failed")
assert(type(exported.data) == "string" and #exported.data > 0, "expected a build code")

assert(responses["12"].error and responses["12"].error.code == -32602, "unknown tool should be -32602")
assert(responses["13"].error and responses["13"].error.code == -32601, "expected method not found")
assert(responses["14"].result ~= nil, "ping failed")
assert(responses["15"].error and responses["15"].error.code == -32602, "non-object params should be -32602")
assert(responses["16"].error and responses["16"].error.code == -32602, "schema violation should be -32602")
assert(responses["17"].error and responses["17"].error.code == -32602, "non-object arguments should be -32602")
assert(responses["20"] and responses["20"].result ~= nil, "null batch element should not drop ping")
local parseErrorFound = false
local invalidRequestCount = 0
local nullIdFound = false
for _, response in ipairs(responseList) do
	if response.error and response.error.code == -32700 then
		parseErrorFound = true
		if response.id == json.null then
			nullIdFound = true
		end
	elseif response.error and response.error.code == -32600 then
		invalidRequestCount = invalidRequestCount + 1
	end
end
assert(parseErrorFound, "expected parse error response")
assert(nullIdFound, "parse errors must include id:null")
assert(invalidRequestCount >= 2, "expected invalid request responses for false/null")
io.stdout:write("PASS stdio first session\n")

local uninitialized = runServer({
	'{"jsonrpc":"2.0","id":1,"method":"ping"}',
}, "uninitialized")
assert(uninitialized["1"].error and uninitialized["1"].error.code == -32600, "requests before initialize must fail")

local badInitialize = runServer({
	'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}',
}, "bad initialize")
assert(badInitialize["1"].error and badInitialize["1"].error.code == -32602, "incomplete initialize must fail")

local newVersionInitialize = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"pob-mcp-test","version":"1"}}}'
local newVersionResponses, newVersionList = runServer({
	newVersionInitialize,
	initialized,
	'[{"jsonrpc":"2.0","id":2,"method":"ping"}]',
}, "new version batch")
local lastNewVersionResponse = newVersionList[#newVersionList]
assert(lastNewVersionResponse.error and lastNewVersionResponse.error.code == -32600, "batch must be rejected for 2025-06-18")
io.stdout:write("PASS stdio protocol edge cases\n")

local importRequests = {
	initialize,
	initialized,
	'{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"build_import","arguments":{"code":' .. string.format("%q", exported.data) .. ',"name":"Imported"}}}',
	'{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"calc_stats","arguments":{"stats":["TotalDPS","Life"]}}}',
}
local importResponses = runServer(importRequests, "import session")
local imported, importError = toolResult(importResponses["2"], "build_import")
assert(not importError, "build_import failed")
assert(imported.name == "Imported", "wrong imported build name")
local importedStats, importedStatsError = toolResult(importResponses["3"], "import calc_stats")
assert(not importedStatsError, "import calc_stats failed")
local difference = math.abs((importedStats.requested.TotalDPS or 0) - (stats.requested.TotalDPS or 0))
assert(difference < 0.0001, "DPS changed after build code round-trip")
io.stdout:write("PASS stdio build code round-trip\n")

if not os.getenv("POB_MCP_USER_PATH") then
	os.remove(userPath)
end
if stderr:match("unexpected") then
	io.stderr:write(stderr)
end
