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

package.path = table.concat({
	toolRoot .. "/?.lua",
	toolRoot .. "/?/init.lua",
	runtime .. "/lua/?.lua",
	runtime .. "/lua/?/init.lua",
	package.path,
}, ";")

local Engine = require("engine.init")
local mcpJson = require("mcp.json")
local userPath = os.getenv("POB_MCP_USER_PATH")
local temporaryUserPath = not userPath
if not userPath then
	userPath = os.tmpname() .. ".pob-mcp"
end

local options = {
	root = root,
	src = root .. "/src",
	runtime = runtime,
	userPath = userPath,
}

local api = Engine.get(options)

local passed = 0
local failed = 0

local function assertTrue(value, message)
	if not value then
		error(message or "expected a truthy value", 2)
	end
end

local function assertEqual(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
	end
end

local function assertNear(actual, expected, tolerance, message)
	if type(actual) ~= "number" or type(expected) ~= "number" or math.abs(actual - expected) > (tolerance or 0.000001) then
		error((message or "numbers differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
	end
end

local function test(name, fn)
	local ok, err = xpcall(fn, debug.traceback)
	if ok then
		passed = passed + 1
		io.stdout:write("PASS " .. name .. "\n")
	else
		failed = failed + 1
		io.stdout:write("FAIL " .. name .. "\n" .. tostring(err) .. "\n")
	end
end

test("meta_info", function()
	local info = api:metaInfo()
	assertTrue(info.pob.version, "missing PoB version")
	assertTrue(info.tree.latest, "missing tree version")
	assertTrue(#info.classes >= 7, "expected classes")
	assertTrue(info.data.uniques > 0, "expected uniques")
end)

test("build_new", function()
	local state = api:newBuild({ name = "Test Build", class = "Witch", ascendancy = "Occultist", level = 90 })
	assertEqual(state.class, "Witch")
	assertEqual(state.ascendancy, "Occultist")
	assertEqual(state.level, 90)
	assertEqual(state.points.used, 0)
end)

test("skills_add_group", function()
	local result = api:skillsAddGroup({
		gems = {
			{ name = "Fireball", level = 20, quality = 20 },
			{ name = "Controlled Destruction", level = 20, quality = 20 },
		},
	})
	assertEqual(result.group_index, 1)
	local state = api:skillsGet()
	assertEqual(#state.groups, 1)
	assertEqual(state.groups[1].gems[1].name, "Fireball")
	assertEqual(state.main_group, 1)
end)

test("calc_stats_main_skill", function()
	local stats = api:calcStats({ stats = { "TotalDPS", "CombinedDPS", "Life" } })
	assertEqual(stats.main_skill.name, "Fireball")
	assertTrue(stats.requested.TotalDPS > 0, "expected positive DPS")
	assertTrue(stats.requested.Life > 0, "expected positive life")
end)

test("passives_search_allocate", function()
	local search = api:passivesSearch({ query = "Deep Wisdom", limit = 5 })
	assertTrue(search.total > 0, "expected Deep Wisdom")
	local before = api:passivesGet().points.used
	local result = api:passivesAllocate({ names = { "Deep Wisdom" } })
	assertEqual(#result.errors, 0)
	assertTrue(#result.added >= 2, "expected the notable and its path nodes")
	assertTrue(result.points.used > before, "expected more points used")
	local state = api:passivesGet()
	local found = false
	for _, node in ipairs(state.allocated) do
		if node.name == "Deep Wisdom" then
			found = true
		end
	end
	assertTrue(found, "Deep Wisdom not allocated")
end)

test("passive_mastery", function()
	local search = api:passivesSearch({ type = "mastery", reachable = true, limit = 50 })
	local node
	for _, candidate in ipairs(search.nodes) do
		if not candidate.ascendancy and candidate.mastery_effects and #candidate.mastery_effects > 0 and candidate.path_cost then
			node = candidate
			break
		end
	end
	assertTrue(node ~= nil, "expected a reachable mastery")
	local effect = node.mastery_effects[1]
	local result = api:passivesAllocate({
		ids = { node.id },
		mastery_effects = { [tostring(node.id)] = effect.id },
	})
	assertEqual(#result.errors, 0)
	local state = api:passivesGet()
	local found
	for _, selection in ipairs(state.mastery_selections) do
		if selection.node_id == node.id then
			found = selection
		end
	end
	assertTrue(found ~= nil, "expected mastery selection")
	assertEqual(found.effect_id, effect.id)
	if #node.mastery_effects > 1 then
		local changed = api:passivesSetMastery({ node_id = node.id, effect_id = node.mastery_effects[2].id })
		assertEqual(changed.effect_id, node.mastery_effects[2].id)
	end
end)

test("mastery_validation", function()
	local normal = api:passivesSearch({ type = "normal", allocated = false, reachable = true, limit = 1 })
	assertTrue(normal.total > 0, "expected an unallocated normal node")
	local result = api:passivesAllocate({
		ids = { normal.nodes[1].id },
		mastery_effects = { [tostring(normal.nodes[1].id)] = 1 },
	})
	assertEqual(#result.errors, 1)
	assertTrue(result.errors[1]:find("not a mastery", 1, true) ~= nil, "expected a non-mastery error")
	local build = api:getBuild()
	local unreachable
	for _, node in pairs(build.spec.nodes) do
		if node.type == "Mastery" and not node.alloc and not node.path and node.masteryEffects and #node.masteryEffects > 0 then
			unreachable = node
			break
		end
	end
	if unreachable then
		local ok = pcall(function()
			api:passivesSetMastery({ node_id = unreachable.id, effect_id = unreachable.masteryEffects[1].id })
		end)
		assertTrue(not ok, "unreachable mastery should fail")
		assertTrue(build.spec.masterySelections[unreachable.id] == nil, "unreachable mastery should not be mutated")
	end
end)

test("items_add_unique", function()
	local search = api:itemsSearchUniques({ query = "Abyssus", limit = 5 })
	assertTrue(search.total > 0, "expected Abyssus")
	local item = api:itemsAddUnique({ name = "Abyssus" })
	assertEqual(item.name, "Abyssus")
	assertEqual(item.equipped_in, "Helmet")
	local variantItem = api:itemsAddUnique({ name = "Abyssus", variant = 1, quality = 30, sockets = "B-B" })
	assertEqual(variantItem.quality, 30)
	assertEqual(variantItem.variant, 1)
	assertEqual(variantItem.socket_count, 2)
	local allItems = api:itemsGet({ include_raw = true })
	local raw
	for _, candidate in ipairs(allItems.items) do
		if candidate.id == variantItem.id then
			raw = candidate.raw
		end
	end
	assertTrue(raw and raw:find("Selected Variant: 1", 1, true), "expected selected variant line")
	assertTrue(raw and raw:find("Sockets: B-B", 1, true), "expected sockets line")
	local zeroQuality = api:itemsAddUnique({ name = "Abyssus", quality = 0, equip = false })
	assertEqual(zeroQuality.quality, 0)
end)

test("items_add_rare_and_equip", function()
	local search = api:itemsSearchBases({ query = "Hubris Circlet", limit = 5 })
	assertTrue(search.total > 0, "expected Hubris Circlet")
	local item = api:itemsAddRare({
		base = "Hubris Circlet",
		name = "Test Circlet",
		mods = { "+100 to maximum Life", "+40% to Fire Resistance" },
		quality = 20,
		sockets = "B-B-B-B",
	})
	assertEqual(item.base, "Hubris Circlet")
	local equipped = api:itemsEquip({ item_id = item.id, slot = "Helmet" })
	assertEqual(equipped.equipped_in, "Helmet")
	local items = api:itemsGet({})
	assertTrue(#items.items >= 2, "expected two items")
end)

test("items_add_and_equip_jewel", function()
	local sockets = api:passivesSearch({ type = "socket", reachable = true, limit = 20 })
	local socketNode
	for _, candidate in ipairs(sockets.nodes) do
		if not candidate.ascendancy and candidate.path_cost then
			socketNode = candidate
			break
		end
	end
	assertTrue(socketNode ~= nil, "expected a reachable jewel socket")
	local allocation = api:passivesAllocate({ ids = { socketNode.id } })
	assertEqual(#allocation.errors, 0)
	local jewel = api:itemsAddRare({
		base = "Cobalt Jewel",
		name = "Test Jewel",
		mods = { "+40 to maximum Energy Shield" },
	})
	assertEqual(jewel.base, "Cobalt Jewel")
	local slot = "Jewel " .. tostring(socketNode.id)
	local equipped = api:itemsEquip({ item_id = jewel.id, slot = slot })
	assertEqual(equipped.equipped_in, slot)
	local items = api:itemsGet({ include_raw = true })
	local found
	for _, item in ipairs(items.items) do
		if item.id == jewel.id then
			found = item
		end
	end
	assertTrue(found ~= nil and found.raw and found.raw:find("Cobalt Jewel", 1, true), "expected jewel raw text")
	api:passivesDeallocate({ ids = { socketNode.id } })
	local after = api:itemsGet({})
	for _, entry in ipairs(after.equipped) do
		assertTrue(entry.slot ~= slot, "deallocated jewel socket should not appear equipped")
	end
end)

test("config_set", function()
	local initial = api:configGet()
	assertTrue(next(initial.set) == nil, "fresh build should not report default config values")
	local encodedInitial = mcpJson.encode(initial)
	assertTrue(encodedInitial:find('"set":{}', 1, true) ~= nil, "empty config set must encode as an object")
	local search = api:configSearch({ query = "onslaught", limit = 5 })
	assertTrue(search.total > 0, "expected Onslaught option")
	local result = api:configSet({ values = { buffOnslaught = true } })
	assertEqual(result.config.set.buffOnslaught, true)
	local fetched = api:configGet()
	assertEqual(fetched.set.buffOnslaught, true)
	local ok = pcall(function()
		api:configSet({ values = { conditionMoving = true, definitelyNotAConfigOption = true } })
	end)
	assertTrue(not ok, "invalid config set should fail")
	assertTrue(api:configGet().set.conditionMoving == nil, "failed config set must not partially mutate")
	local beforeLife = api:calcStats({ stats = { "Life" } }).requested.Life
	api:configSet({ custom_mods = "+100 to maximum Life" })
	local afterLife = api:calcStats({ stats = { "Life" } }).requested.Life
	assertTrue(afterLife > beforeLife, "custom modifier did not increase life")
	assertEqual(api:configGet().set.customMods, "+100 to maximum Life")
end)

test("calc_breakdown", function()
	local breakdown = api:calcBreakdown({ stat = "Life" })
	assertTrue(breakdown.value ~= nil, "expected Life value")
end)

test("snapshot_restore", function()
	local before = api:passivesGet().points.used
	local snapshot = api:snapshot({ name = "before-extra-node" })
	assertTrue(snapshot.bytes > 0, "expected snapshot bytes")
	local search = api:passivesSearch({ type = "notable", reachable = true, allocated = false, limit = 20 })
	local node
	for _, candidate in ipairs(search.nodes) do
		if not candidate.ascendancy then
			node = candidate
			break
		end
	end
	assertTrue(node ~= nil, "expected another reachable main-tree notable")
	local result = api:passivesAllocate({ ids = { node.id } })
	assertEqual(#result.errors, 0)
	assertTrue(api:passivesGet().points.used > before, "expected allocation to add points")
	api:restore({ name = "before-extra-node" })
	assertEqual(api:passivesGet().points.used, before)
	assertEqual(api:configGet().set.customMods, "+100 to maximum Life")
end)

test("build_code_roundtrip", function()
	local before = api:calcStats({ stats = { "TotalDPS", "Life" } }).requested
	local exported = api:exportBuild({ format = "code" })
	assertTrue(exported.data and #exported.data > 0, "expected build code")
	local xml = api:exportBuild({ format = "xml" })
	assertTrue(xml.data and #xml.data > 0, "expected XML")
	local imported = api:importBuild({ code = exported.data, name = "Imported" })
	assertEqual(imported.name, "Imported")
	local after = api:calcStats({ stats = { "TotalDPS", "Life" } }).requested
	assertNear(after.TotalDPS, before.TotalDPS, 0.0001, "DPS changed after round-trip")
	assertNear(after.Life, before.Life, 0.0001, "Life changed after round-trip")
	local fromXML = api:importBuild({ xml = xml.data, name = "From XML" })
	assertEqual(fromXML.name, "From XML")
	local beforeLegacy = api:calcStats({ stats = { "TotalDPS", "Life" } }).requested
	local legacyOk, legacyError = pcall(function()
		api:importBuild({
			xml = '<PathOfBuilding><Build level="1" className="Witch"/></PathOfBuilding>',
			name = "Legacy",
			convert = false,
		})
	end)
	assertTrue(not legacyOk, "legacy import without convert should fail")
	assertTrue(tostring(legacyError):find("conversion", 1, true) ~= nil or tostring(legacyError):find("dialog", 1, true) ~= nil, "expected a conversion error")
	local afterLegacy = api:calcStats({ stats = { "TotalDPS", "Life" } }).requested
	assertNear(afterLegacy.TotalDPS, beforeLegacy.TotalDPS, 0.0001, "build was not restored after failed import")
	assertNear(afterLegacy.Life, beforeLegacy.Life, 0.0001, "build was not restored after failed import")
	local path = os.tmpname()
	local written = api:exportBuild({ format = "code", path = path })
	assertEqual(written.path, path)
	local file = assert(io.open(path, "rb"))
	local code = file:read("*a")
	file:close()
	os.remove(path)
	assertEqual(code, exported.data)
end)

test("skills_search", function()
	local active = api:skillsSearch({ query = "Fireball", kind = "active", limit = 10 })
	assertTrue(active.total > 0, "expected Fireball")
	local support = api:skillsSearch({ query = "Controlled Destruction", kind = "support", limit = 10 })
	assertTrue(support.total > 0, "expected Controlled Destruction")
	assertEqual(support.gems[1].support, true)
end)

test("skills_set_main_remove", function()
	local added = api:skillsAddGroup({
		gems = {
			{ name = "Fireball", level = 20, quality = 0 },
			{ name = "High-Impact Mine", level = 20, quality = 0 },
		},
		set_main = false,
	})
	local groupIndex = added.group_index
	api:skillsSetMain({ group = groupIndex })
	assertEqual(api:skillsGet().main_group, groupIndex)
	local before = #api:skillsGet().groups
	api:skillsRemoveGroup({ group = groupIndex })
	assertEqual(#api:skillsGet().groups, before - 1)
	assertEqual(api:skillsGet().main_group, 1)
end)

test("character_set_and_warnings", function()
	local state = api:characterSet({ level = 95 })
	assertEqual(state.level, 95)
	local warnings = api:calcWarnings()
	assertTrue(type(warnings.warnings) == "table", "expected warnings array")
end)

test("passives_deallocate", function()
	local before = api:passivesGet()
	local target
	for _, node in ipairs(before.allocated) do
		if node.name == "Deep Wisdom" then
			target = node
		end
	end
	assertTrue(target ~= nil, "expected Deep Wisdom to deallocate")
	local result = api:passivesDeallocate({ ids = { target.id } })
	local removed = false
	for _, node in ipairs(result.removed) do
		if node.id == target.id then
			removed = true
		end
	end
	assertTrue(removed, "expected Deep Wisdom in removed list")
end)

test("build_validate", function()
	api:snapshot({ name = "validate-backup" })
	api:newBuild({ class = "Witch", level = 69 })
	api:itemsAddRare({ base = "Glorious Plate", name = "Validation Plate", mods = { "+50 to maximum Life" } })
	api:itemsAddUnique({ name = "Choir of the Storm" })
	local validation = api:validateBuild()
	assertTrue(type(validation.errors) == "table", "expected validation errors array")
	assertTrue(type(validation.warnings) == "table", "expected validation warnings array")
	assertTrue(not validation.valid, "expected the test build to report its attribute requirements")
	local found
	for _, validationError in ipairs(validation.errors) do
		if validationError.code == "attribute_requirements" then
			found = true
		end
		assertTrue(validationError.code ~= "socket_link", "granted skills should not require socket links")
	end
	assertTrue(found, "expected an attribute requirement validation error")
	api:restore({ name = "validate-backup" })
end)

test("passives_plan_and_what_if", function()
	api:snapshot({ name = "plan-backup" })
	api:newBuild({ class = "Witch", level = 95 })
	local search = api:passivesSearch({ type = "notable", allocated = false, reachable = true, limit = 10 })
	assertTrue(search.total > 0, "expected a reachable notable")
	local node = search.nodes[1]
	local plan = api:passivesPlan({ ids = { node.id } })
	assertTrue(plan.cost > 0, "expected a non-zero point cost")
	assertTrue(plan.within_budget, "expected the plan to fit the budget")
	local before = api:passivesGet().points.used
	local whatIf = api:calcWhatIf({ add_node_ids = { node.id }, stats = { "Life" } })
	assertTrue(whatIf.result ~= nil, "expected what-if output")
	assertTrue(whatIf.changes.add_node_ids ~= nil, "expected what-if changes")
	assertEqual(api:passivesGet().points.used, before)
	local masteries = api:passivesSearch({ type = "mastery", allocated = false, reachable = true, limit = 1 })
	if masteries.total > 0 then
		local ok = pcall(function()
			api:calcWhatIf({ add_node_ids = { masteries.nodes[1].id } })
		end)
		assertTrue(not ok, "mastery what-if should be rejected")
	end
	api:restore({ name = "plan-backup" })
end)

test("items_compare", function()
	api:snapshot({ name = "compare-backup" })
	api:newBuild({ class = "Witch", level = 95 })
	api:itemsAddRare({ base = "Ruby Ring", name = "Equipped Ring", mods = { "+50 to maximum Life", "+40% to Fire Resistance" } })
	local raw = "Rarity: RARE\nCompare Ring\nRuby Ring\nItem Level: 80\nQuality: 20\nImplicits: 1\n+40% to Fire Resistance\n+100 to maximum Life\n+45% to Cold Resistance\n+45% to Lightning Resistance"
	local comparison = api:itemsCompare({ item_raw = raw, slot = "Ring 1", stats = { "Life", "FireResist" } })
	assertTrue(comparison.base_requested.Life ~= nil, "expected a base Life value")
	assertTrue(comparison.result_requested.Life ~= nil, "expected a comparison Life value")
	assertTrue(comparison.changes.item ~= nil, "expected the compared item summary")
	local invalidSlot = pcall(function()
		api:itemsCompare({ item_raw = raw, slot = "Not A Slot" })
	end)
	assertTrue(not invalidSlot, "invalid comparison slots should be rejected")
	api:restore({ name = "compare-backup" })
end)

test("constraints_survive_restore", function()
	api:newBuild({ class = "Scion", ascendancy = "Ascendant", level = 69 })
	api:setConstraints({ level = 69, no_uniques = true, enforce_points = true })
	api:snapshot({ name = "constraints-snapshot" })
	api:newBuild({ class = "Witch", level = 90 })
	api:restore({ name = "constraints-snapshot" })
	local constraints = api:getConstraints()
	assertEqual(constraints.level, 69)
	assertEqual(constraints.no_uniques, true)
	assertEqual(constraints.enforce_points, true)
end)

test("constraints_and_item_requirements", function()
	api:newBuild({ class = "Scion", ascendancy = "Ascendant", level = 69 })
	api:setConstraints({ level = 69, no_uniques = true, enforce_points = true })
	local validation = api:validateBuild()
	assertEqual(validation.unique_count, 0)
	assertTrue(validation.valid, "fresh constrained build should be valid")
	local search = api:passivesSearch({ type = "notable", allocated = false, reachable = true, limit = 20 })
	local node
	for _, candidate in ipairs(search.nodes) do
		if not candidate.ascendancy then
			node = candidate
			break
		end
	end
	assertTrue(node ~= nil, "expected a reachable main-tree notable")
	local plan = api:passivesPlan({ ids = { node.id } })
	assertTrue(plan.cost > 0, "expected a planned allocation")
	assertTrue(plan.within_budget, "expected the plan to fit level 69")
	local okUnique = pcall(function()
		api:itemsAddUnique({ name = "Abyssus" })
	end)
	assertTrue(not okUnique, "unique items should be rejected")
	local okLevel = pcall(function()
		api:itemsAddRaw({ raw = "Rarity: RARE\nRare Amulet\nMarble Amulet\nItem Level: 80\nQuality: 20\nImplicits: 0\n+60 to maximum Life" })
	end)
	assertTrue(not okLevel, "items above character level should be rejected")
	api:setConstraints({ max_points = 0, enforce_points = true })
	local okBudget = pcall(function()
		api:passivesAllocate({ ids = { node.id } })
	end)
	assertTrue(not okBudget, "allocations over the configured budget should be rejected")
	local allowed = api:passivesAllocate({ ids = { node.id }, allow_over_budget = true })
	assertTrue(allowed.points.used > 0, "expected the over-budget allocation to succeed: " .. mcpJson.encode(allowed))
	local overBudget = api:validateBuild()
	assertTrue(not overBudget.valid, "over-budget builds should be invalid: " .. mcpJson.encode(overBudget.errors))
end)

test("invalid_requests", function()
	local okNode = pcall(function()
		api:passivesAllocate({ names = { "Definitely Not A Node" } })
	end)
	assertTrue(not okNode, "expected unknown node to fail")
	local okBase = pcall(function()
		api:itemsAddRare({ base = "Definitely Not A Base" })
	end)
	assertTrue(not okBase, "expected unknown base to fail")
	local okDuplicate, duplicateError = pcall(function()
		api:passivesAllocate({ names = { "Spell Damage" } })
	end)
	assertTrue(not okDuplicate and tostring(duplicateError):find("ambiguous", 1, true) ~= nil, "expected duplicate names to be rejected")
	local beforeItems = #api:itemsGet({}).items
	local okSlot = pcall(function()
		api:itemsAddRaw({ raw = "Rarity: Normal\nCoral Ring", slot = "Not A Slot" })
	end)
	assertTrue(not okSlot, "expected invalid slot to fail")
	assertEqual(#api:itemsGet({}).items, beforeItems)
	local okRing3 = pcall(function()
		api:itemsAddRaw({
			raw = "Rarity: Rare\nTest Ring\nCoral Ring\nImplicits: 0\n+10 to maximum Life",
			slot = "Ring 3",
		})
	end)
	assertTrue(not okRing3, "expected inactive Ring 3 to fail")
	assertEqual(#api:itemsGet({}).items, beforeItems)
end)

if temporaryUserPath then
	os.remove(userPath)
end

io.stdout:write(string.format("\n%d passed, %d failed\n", passed, failed))
if failed > 0 then
	os.exit(1)
end
