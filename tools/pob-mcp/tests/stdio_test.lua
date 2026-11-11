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

package.path = runtime .. "/lua/?.lua;" .. runtime .. "/lua/?/init.lua;" .. package.path
local json = require("dkjson")

local luajit = os.getenv("POB_MCP_LUAJIT") or "luajit"
local mainScript = toolRoot .. "/main.lua"

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
		shellQuote(luajit),
		shellQuote(mainScript),
		"< " .. shellQuote(requestPath),
		"> " .. shellQuote(outputPath),
		"2> " .. shellQuote(errorPath),
	}, " ")
	local ok = os.execute(command)
	local responses = {}
	local responseList = {}
	local output = assert(io.open(outputPath, "rb"))
	for line in output:lines() do
		if line:match("%S") then
			local decoded, err = json.decode(line)
			assert(decoded, "invalid JSON response in " .. label .. ": " .. tostring(err) .. "\n" .. line)
			responseList[#responseList + 1] = decoded
			if decoded.id ~= nil then
				responses[tostring(decoded.id)] = decoded
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
	assert(ok, "server failed for " .. label .. "\n" .. stderr)
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

local initialize = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}'
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

local missing, missingError = toolResult(responses["12"], "missing_tool")
assert(missingError == true, "missing tool should be an error")
assert(type(missing) == "string", "missing tool should return text")
assert(responses["13"].error and responses["13"].error.code == -32601, "expected method not found")
assert(responses["14"].result ~= nil, "ping failed")
local parseErrorFound = false
for _, response in ipairs(responseList) do
	if response.error and response.error.code == -32700 then
		parseErrorFound = true
	end
end
assert(parseErrorFound, "expected parse error response")
io.stdout:write("PASS stdio first session\n")

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

if stderr:match("unexpected") then
	io.stderr:write(stderr)
end
