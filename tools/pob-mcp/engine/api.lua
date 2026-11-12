local util = require("engine.util")
local codec = require("engine.codec")

local M = {}

local function objectMap(value)
	if type(value) == "table" then
		setmetatable(value, { __jsontype = "object" })
	end
	return value
end

local function questPointsForLevel(level)
	if level >= 67 then
		return 23
	elseif level >= 64 then
		return 20
	elseif level >= 60 then
		return 18
	elseif level >= 54 then
		return 15
	elseif level >= 50 then
		return 12
	elseif level >= 44 then
		return 9
	elseif level >= 40 then
		return 7
	elseif level >= 32 then
		return 6
	elseif level >= 22 then
		return 4
	elseif level >= 12 then
		return 2
	end
	return 0
end

local function socketInfo(item)
	local counts = {}
	local total = 0
	local abyssal = 0
	local maximum = 0
	for _, socket in ipairs(item and item.sockets or {}) do
		if socket.color == "A" then
			abyssal = abyssal + 1
		else
			total = total + 1
			counts[socket.group] = (counts[socket.group] or 0) + 1
			if counts[socket.group] > maximum then
				maximum = counts[socket.group]
			end
		end
	end
	local socketLimit = item and item.base and item.base.socketLimit or nil
	return {
		total = total,
		abyssal = abyssal,
		max_linked = maximum,
		socket_limit = socketLimit,
		capacity = socketLimit and math.max(0, socketLimit - abyssal) or nil,
	}
end

local function maxLinkedSockets(item)
	return socketInfo(item).max_linked
end

local function socketString(item)
	local groups = {}
	local output = {}
	for _, socket in ipairs(item and item.sockets or {}) do
		if not groups[socket.group] then
			groups[socket.group] = {}
			output[#output + 1] = groups[socket.group]
		end
		table.insert(groups[socket.group], socket.color)
	end
	local parts = {}
	for _, group in ipairs(output) do
		parts[#parts + 1] = table.concat(group, "-")
	end
	return table.concat(parts, " ")
end

local function parseSocketString(text)
	local sockets = {}
	local groupId = 0
	for segment in tostring(text):gmatch("%S+") do
		local clean = segment:gsub("%-", "")
		if clean == "" or not clean:match("^[RGBWA]+$") then
			error("Invalid socket segment '" .. segment .. "'", 0)
		end
		groupId = groupId + 1
		for color in clean:gmatch(".") do
			sockets[#sockets + 1] = { color = color, group = groupId }
		end
	end
	if #sockets == 0 then
		error("Socket string is empty", 0)
	end
	return sockets
end

local ffi = require("ffi")
local isWindows = package.config:sub(1, 1) == "\\"
if isWindows then
	pcall(ffi.cdef, [[
int _mkdir(const char *path);
]])
else
	pcall(ffi.cdef, [[
int mkdir(const char *path, unsigned int mode);
]])
end

local function ensureDir(path)
	local current = path:match("^[/\\]") and "" or nil
	for part in tostring(path):gmatch("[^/\\]+") do
		if current == nil then
			current = part
		else
			current = current .. "/" .. part
		end
		if isWindows then
			pcall(ffi.C._mkdir, current)
		else
			pcall(ffi.C.mkdir, current, 493)
		end
	end
end

local function shellQuote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function normaliseBuildName(name)
	local text = util.trim(tostring(name or ""))
	if text == "" or text:find("[/\\]") or text:find("%.%.") then
		error("Invalid build name '" .. tostring(name) .. "'", 0)
	end
	return text:gsub("%.xml$", "")
end

local function writeFileAtomic(path, data)
	local temp = path .. ".tmp"
	local file, err = io.open(temp, "wb")
	if not file then
		error("Could not write '" .. path .. "': " .. tostring(err), 0)
	end
	local ok, writeError = file:write(data)
	if not ok then
		file:close()
		os.remove(temp)
		error("Could not write '" .. path .. "': " .. tostring(writeError), 0)
	end
	local closed, closeError = file:close()
	if not closed then
		os.remove(temp)
		error("Could not close '" .. path .. "': " .. tostring(closeError), 0)
	end
	local renamed, renameError = os.rename(temp, path)
	if not renamed then
		os.remove(temp)
		error("Could not finalize '" .. path .. "': " .. tostring(renameError), 0)
	end
end

local function listXmlFiles(directory)
	local files = {}
	if isWindows then
		local pipe = io.popen('dir /b /s /a-d "' .. tostring(directory) .. '" 2>nul')
		if pipe then
			for path in pipe:lines() do
				if path:lower():match("%.xml$") then
					files[#files + 1] = path:gsub("\\", "/")
				end
			end
			pipe:close()
		end
	else
		local pipe = io.popen("find " .. shellQuote(directory) .. " -type f -name '*.xml' -print 2>/dev/null")
		if pipe then
			for path in pipe:lines() do
				files[#files + 1] = path
			end
			pipe:close()
		end
	end
	return files
end

local function readBuildHeader(path)
	local file = io.open(path, "rb")
	if not file then
		return nil
	end
	local text = file:read(2048)
	file:close()
	if not text then
		return nil
	end
	local tag = text:match("<Build%s+[^>]->")
	if not tag then
		return {}
	end
	return {
		level = tonumber(tag:match('level="([^"]+)"')),
		className = tag:match('className="([^"]+)"'),
		ascendClassName = tag:match('ascendClassName="([^"]+)"'),
	}
end

local function normaliseStatText(value)
	return util.lower(tostring(value or "")):gsub("[^%w]+", "")
end

local function fuzzyStatMatch(haystack, needle)
	if needle == "" then
		return true, 0
	end
	local direct = haystack:find(needle, 1, true)
	if direct then
		return true, 1000 - direct
	end
	local position = 1
	local gaps = 0
	for index = 1, #needle do
		local found = haystack:find(needle:sub(index, index), position, true)
		if not found then
			return false, 0
		end
		gaps = gaps + (found - position)
		position = found + 1
	end
	return true, 100 - gaps
end

local Api = {}
Api.__index = Api

local curatedStatKeys = {
	"CombinedDPS",
	"FullDPS",
	"TotalDPS",
	"TotalDot",
	"WithDotDPS",
	"WithBleedDPS",
	"WithIgniteDPS",
	"WithPoisonDPS",
	"TotalDotDPS",
	"AverageHit",
	"AverageDamage",
	"Speed",
	"HitChance",
	"PreEffectiveCritChance",
	"CritChance",
	"CritMultiplier",
	"Life",
	"LifeUnreserved",
	"LifeRegenRecovery",
	"Mana",
	"ManaUnreserved",
	"ManaRegenRecovery",
	"EnergyShield",
	"EnergyShieldRegenRecovery",
	"Armour",
	"Evasion",
	"BlockChance",
	"SpellBlockChance",
	"SpellSuppressionChance",
	"FireResist",
	"ColdResist",
	"LightningResist",
	"ChaosResist",
	"Str",
	"Dex",
	"Int",
	"Omni",
	"MovementSpeed",
	"EffectiveMovementSpeedMod",
	"ManaCost",
	"Cooldown",
}

local groupSlotOrder = {
	"Weapon 1",
	"Weapon 2",
	"Weapon 1 Swap",
	"Weapon 2 Swap",
	"Helmet",
	"Body Armour",
	"Gloves",
	"Boots",
	"Amulet",
	"Ring 1",
	"Ring 2",
	"Ring 3",
	"Belt",
}

local groupSlots = {
	["Weapon 1"] = true,
	["Weapon 2"] = true,
	["Weapon 1 Swap"] = true,
	["Weapon 2 Swap"] = true,
	["Helmet"] = true,
	["Body Armour"] = true,
	["Gloves"] = true,
	["Boots"] = true,
	["Amulet"] = true,
	["Ring 1"] = true,
	["Ring 2"] = true,
	["Ring 3"] = true,
	["Belt"] = true,
}

function M.new(env)
	local self = setmetatable({}, Api)
	self.env = env
	self.snapshots = {}
	self.snapshotConstraints = {}
	self.snapshotCounter = 0
	self.constraints = {
		level = nil,
		max_points = nil,
		no_uniques = false,
		enforce_points = false,
	}
	return self
end

function Api:getBuild()
	return self.env.main.modes["BUILD"]
end

function Api:setConstraints(options)
	options = options or {}
	local constraints = self.constraints
	local build = self:getBuild()
	if options.level ~= nil then
		local level = tonumber(options.level)
		if not level then
			error("Constraint level must be a number", 0)
		end
		constraints.level = util.clamp(math.floor(level), 1, 100)
		build.characterLevel = constraints.level
		build.characterLevelAutoMode = false
		build.configTab:BuildModList()
		build.buildFlag = true
		if options.enforce_points == nil then
			constraints.enforce_points = true
		end
	end
	if options.max_points ~= nil then
		local maxPoints = tonumber(options.max_points)
		if not maxPoints then
			error("max_points must be a number", 0)
		end
		constraints.max_points = math.max(0, math.floor(maxPoints))
	end
	if options.no_uniques ~= nil then
		constraints.no_uniques = options.no_uniques == true
	end
	if options.enforce_points ~= nil then
		constraints.enforce_points = options.enforce_points == true
	end
	if options.level ~= nil or options.max_points ~= nil then
		self:frame()
	end
	return self:getConstraints()
end

function Api:getConstraints()
	return {
		level = self.constraints.level,
		max_points = self.constraints.max_points,
		no_uniques = self.constraints.no_uniques,
		enforce_points = self.constraints.enforce_points,
	}
end

function Api:pointBudget(build)
	build = build or self:getBuild()
	local level = self.constraints.level or build.characterLevel or 1
	local extra = build.calcsTab.mainOutput and build.calcsTab.mainOutput.ExtraPoints or 0
	local maximum = (level - 1) + questPointsForLevel(level) + extra
	if self.constraints.max_points then
		maximum = math.min(maximum, self.constraints.max_points)
	end
	local used, ascendancyUsed, secondaryUsed = build.spec:CountAllocNodes()
	return {
		level = level,
		quest_points = questPointsForLevel(level),
		extra_points = extra,
		max = maximum,
		used = used,
		unspent = maximum - used,
		ascendancy_used = ascendancyUsed,
		ascendancy_max = 8,
		secondary_ascendancy_used = secondaryUsed,
		secondary_ascendancy_max = 8,
	}
end

function Api:checkPrompt()
	local message = self.env.launch.promptMsg
	if message then
		self.env.launch.promptMsg = nil
		message = util.stripColors(message)
		message = message:gsub("^%s*Error:%s*", "")
		message = message:gsub("\nv[%d%.]+[^\n]*", "")
		message = message:gsub("\nPress Enter/Escape.*$", "")
		error(util.trim(message), 0)
	end
	local popups = self.env.main.popups
	if popups and popups[1] then
		self.env.main.popups = {}
		error("PoB blocked the operation with a dialog; the build may require conversion", 0)
	end
end

function Api:checkBuildInitialized(build)
	if not build.targetVersion then
		error("Build requires conversion; import with convert=true", 0)
	end
end

function Api:frame()
	local build = self:getBuild()
	build.buildFlag = true
	self.env.runCallback("OnFrame")
	self:checkPrompt()
	self:checkBuildInitialized(build)
	if build.itemsTab and build.itemsTab.UpdateSockets then
		build.itemsTab:UpdateSockets()
	end
	return build
end

function Api:resolvePath(path)
	if not path or path == "" then
		return path
	end
	if path:match("^[/\\]") or path:match("^%a:[/\\]") then
		return path
	end
	return self.env.root .. "/" .. path
end

function Api:classList()
	local build = self:getBuild()
	local tree = build.spec.tree
	local output = {}
	for classId, class in pairs(tree.classes) do
		if type(classId) == "number" then
			local ascendancies = {}
			for ascendId, ascendancy in pairs(class.classes) do
				if type(ascendId) == "number" then
					ascendancies[#ascendancies + 1] = {
						id = ascendId,
						name = ascendancy.name,
						internal_id = ascendancy.id,
					}
				end
			end
			table.sort(ascendancies, function(a, b)
				return a.id < b.id
			end)
			output[#output + 1] = {
				id = classId,
				name = class.name,
				ascendancies = ascendancies,
			}
		end
	end
	table.sort(output, function(a, b)
		return a.id < b.id
	end)
	return output
end

function Api:resolveClass(reference)
	if reference == nil then
		return nil
	end
	local build = self:getBuild()
	local tree = build.spec.tree
	if type(reference) == "string" and tonumber(reference) then
		reference = tonumber(reference)
	end
	if type(reference) == "number" then
		if tree.classes[reference] then
			return reference
		end
		return nil, "Unknown class id '" .. tostring(reference) .. "'"
	end
	local target = util.lower(util.trim(tostring(reference)))
	for classId, class in pairs(tree.classes) do
		if type(classId) == "number" and util.lower(class.name) == target then
			return classId
		end
	end
	return nil, "Unknown class '" .. tostring(reference) .. "'"
end

function Api:resolveAscendancy(classId, reference)
	if reference == nil then
		return nil
	end
	local build = self:getBuild()
	local class = build.spec.tree.classes[classId]
	if not class then
		return nil, "Unknown class id '" .. tostring(classId) .. "'"
	end
	if type(reference) == "string" and tonumber(reference) then
		reference = tonumber(reference)
	end
	if type(reference) == "number" then
		if class.classes[reference] then
			return reference
		end
		return nil, "Unknown ascendancy id '" .. tostring(reference) .. "'"
	end
	local target = util.lower(util.trim(tostring(reference)))
	if target == "none" then
		return 0
	end
	for ascendId, ascendancy in pairs(class.classes) do
		if type(ascendId) == "number" and (util.lower(ascendancy.name) == target or util.lower(ascendancy.id or "") == target) then
			return ascendId
		end
	end
	return nil, "Unknown ascendancy '" .. tostring(reference) .. "' for class " .. class.name
end

function Api:countAllocatedNonStart(build)
	local count = 0
	for _, node in pairs(build.spec.allocNodes) do
		if node.type ~= "ClassStart" and node.type ~= "AscendClassStart" then
			count = count + 1
		end
	end
	return count
end

function Api:applyCharacter(build, options)
	options = options or {}
	local classId
	if options.class ~= nil then
		local resolved, err = self:resolveClass(options.class)
		if not resolved then
			error(err, 0)
		end
		classId = resolved
	end
	if classId ~= nil and classId ~= build.spec.curClassId then
		if self:countAllocatedNonStart(build) > 0 and not build.spec:IsClassConnected(classId) then
			error("Cannot change class while the allocated passives are not connected to the new class", 0)
		end
		build.spec:SelectClass(classId)
	end
	if options.ascendancy ~= nil then
		local ascendId, err = self:resolveAscendancy(build.spec.curClassId, options.ascendancy)
		if ascendId == nil then
			error(err, 0)
		end
		build.spec:SelectAscendClass(ascendId)
	end
	if options.level ~= nil then
		local level = tonumber(options.level)
		if not level then
			error("Level must be a number", 0)
		end
		build.characterLevel = util.clamp(math.floor(level), 1, 100)
		build.characterLevelAutoMode = false
	end
	if options.level ~= nil or options.class ~= nil or options.ascendancy ~= nil then
		build.configTab:BuildModList()
		build.buildFlag = true
	end
end

function Api:mainSkillInfo(build)
	local groupIndex = build.mainSocketGroup or 1
	local group = build.skillsTab.socketGroupList[groupIndex]
	local environment = build.calcsTab.mainEnv
	local skill = environment and environment.player and environment.player.mainSkill
	local effect = skill and skill.activeEffect
	local granted = effect and effect.grantedEffect
	local info = {
		group = groupIndex,
		active = group and group.mainActiveSkill or 1,
		name = granted and granted.name or (group and (group.displayLabel or group.label)) or nil,
		level = effect and effect.level or nil,
		quality = effect and effect.quality or nil,
		part = skill and skill.skillPartName or nil,
	}
	if environment and environment.minion and environment.minion.minionData then
		info.minion = environment.minion.minionData.name
	end
	return info
end

function Api:curatedStats(output)
	local stats = {}
	for _, key in ipairs(curatedStatKeys) do
		local value = output[key]
		if type(value) == "number" then
			stats[key] = util.sanitize(value)
		end
	end
	return stats
end

function Api:warnings(build)
	local output = {}
	local seen = {}
	local function add(line)
		if line == nil or line == "" then
			return
		end
		line = util.stripColors(tostring(line))
		if not seen[line] then
			seen[line] = true
			output[#output + 1] = line
		end
	end
	local lines = build.controls and build.controls.warnings and build.controls.warnings.lines or {}
	for _, line in ipairs(lines) do
		add(line)
	end
	local environment = build.calcsTab and build.calcsTab.mainEnv
	if environment and environment.player and environment.player.mainSkill then
		add(environment.player.mainSkill.infoMessage)
		add(environment.player.mainSkill.infoMessage2)
		add(environment.player.mainSkill.disableReason)
	end
	return output
end

function Api:points(build)
	return self:pointBudget(build)
end

function Api:validateBuild()
	local build = self:getBuild()
	local errors = {}
	local warnings = {}
	local seenErrors = {}
	local seenWarnings = {}
	local function addError(code, message)
		local key = code .. ":" .. message
		if not seenErrors[key] then
			seenErrors[key] = true
			errors[#errors + 1] = { code = code, message = message }
		end
	end
	local function addWarning(code, message)
		local key = code .. ":" .. message
		if not seenWarnings[key] then
			seenWarnings[key] = true
			warnings[#warnings + 1] = { code = code, message = message }
		end
	end
	local points = self:pointBudget()
	if points.used > points.max then
		addError("point_budget", string.format("Build uses %d passive points but level %d allows at most %d", points.used, points.level, points.max))
	end
	if points.ascendancy_used > points.ascendancy_max then
		addError("ascendancy_budget", string.format("Build uses %d ascendancy points but only %d are allowed", points.ascendancy_used, points.ascendancy_max))
	end
	if points.secondary_ascendancy_used > points.secondary_ascendancy_max then
		addError("secondary_ascendancy_budget", string.format("Build uses %d secondary ascendancy points but only %d are allowed", points.secondary_ascendancy_used, points.secondary_ascendancy_max))
	end
	local uniqueCount = 0
	local itemsTab = build.itemsTab
	for _, item in pairs(itemsTab and itemsTab.items or {}) do
		if item.rarity == "UNIQUE" or item.rarity == "RELIC" then
			uniqueCount = uniqueCount + 1
		end
	end
	if self.constraints.no_uniques and uniqueCount > 0 then
		addError("no_uniques", string.format("Build contains %d unique item(s) but no_uniques is enabled", uniqueCount))
	end
	local output = build.calcsTab.mainOutput or {}
	for _, slot in ipairs(itemsTab and itemsTab.orderedSlots or {}) do
		local item = itemsTab.items[slot.selItemId]
		if item and slot:IsShown() then
			local requirements = item.requirements or {}
			if requirements.level and requirements.level > build.characterLevel then
				addError("item_level", string.format("%s requires level %d but the character is level %d", slot.slotName, requirements.level, build.characterLevel))
			end
		end
	end
	if (output.ReqStr or 0) > (output.Str or 0) then
		addError("attribute_requirements", string.format("Build requires %d Strength but has %d", output.ReqStr or 0, output.Str or 0))
	end
	if (output.ReqDex or 0) > (output.Dex or 0) then
		addError("attribute_requirements", string.format("Build requires %d Dexterity but has %d", output.ReqDex or 0, output.Dex or 0))
	end
	if (output.ReqInt or 0) > (output.Int or 0) then
		addError("attribute_requirements", string.format("Build requires %d Intelligence but has %d", output.ReqInt or 0, output.Int or 0))
	end
	local slotGemCounts = {}
	for index, group in ipairs(build.skillsTab and build.skillsTab.socketGroupList or {}) do
		if group.enabled ~= false and not group.source then
			local label = group.displayLabel or group.label or ("Skill group " .. index)
			if not group.slot then
				addWarning("skill_slot", label .. " is not socketed in an item")
			else
				local slot = itemsTab and itemsTab.slots[group.slot]
				local item = slot and itemsTab.items[slot.selItemId]
				if not item then
					addError("skill_slot", label .. " is socketed in an empty " .. group.slot .. " slot")
				else
					local linked = maxLinkedSockets(item)
					if linked < #(group.gemList or {}) then
						addWarning("socket_link", label .. " needs " .. #(group.gemList or {}) .. " linked sockets but " .. group.slot .. " has " .. linked)
					end
					local count = 0
					for _, gem in ipairs(group.gemList or {}) do
						if gem.enabled ~= false and (gem.gemData or gem.grantedEffect) then
							count = count + 1
						end
					end
					slotGemCounts[group.slot] = (slotGemCounts[group.slot] or 0) + count
					local diagnostics = self:skillSlotDiagnostics(group)
					for _, diagnosticsGroup in ipairs(diagnostics and diagnostics.groups or {}) do
						for _, mismatch in ipairs(diagnosticsGroup.mismatches or {}) do
							addWarning("socket_color", label .. " has a socket color mismatch: " .. mismatch)
						end
					end
				end
			end
			for _, gem in ipairs(group.gemList or {}) do
				if gem.enabled ~= false and gem.reqLevel and gem.reqLevel > build.characterLevel then
					addError("gem_level", string.format("%s requires level %d but the character is level %d", gem.nameSpec or "Gem", gem.reqLevel, build.characterLevel))
				end
				if gem.errMsg then
					addWarning("gem", gem.errMsg)
				end
			end
		end
	end
	for slotName, count in pairs(slotGemCounts) do
		local slot = itemsTab and itemsTab.slots[slotName]
		local item = slot and itemsTab.items[slot.selItemId]
		if item then
			local info = socketInfo(item)
			if count > info.total then
				addWarning("socket_capacity", string.format("%s has %d gems but only %d normal gem sockets", slotName, count, info.total))
			end
		end
	end
	local mainSkill = self:mainSkillInfo(build)
	local isRighteousFire = mainSkill.name == "Righteous Fire" or mainSkill.name == "Righteous Fire of Arcane Devotion"
	if isRighteousFire then
		local netRegen = output.NetLifeRegen
		if type(netRegen) ~= "number" then
			addWarning("rf_sustain", "Could not determine Righteous Fire net life regen")
		elseif netRegen <= 0 then
			addError("rf_sustain", string.format("Righteous Fire is not sustainable: net life regen is %.2f per second", netRegen))
		end
	end
	if (output.MissingFireResist or 0) > 0 then
		addWarning("resistance", string.format("Missing %d%% Fire Resistance", output.MissingFireResist))
	end
	if (output.MissingColdResist or 0) > 0 then
		addWarning("resistance", string.format("Missing %d%% Cold Resistance", output.MissingColdResist))
	end
	if (output.MissingLightningResist or 0) > 0 then
		addWarning("resistance", string.format("Missing %d%% Lightning Resistance", output.MissingLightningResist))
	end
	if (output.ChaosResist or 0) < 0 then
		addWarning("resistance", string.format("Chaos resistance is %d%%", output.ChaosResist or 0))
	end
	if output.ManaHasCost then
		local payable = output.ManaCostPayablePool or output.ManaUnreserved or 0
		if (output.ManaCost or 0) > payable then
			addError("mana_cost", string.format("Main skill costs %d mana but only %d is payable", output.ManaCost or 0, payable))
		end
	end
	for _, warning in ipairs(self:warnings(build)) do
		addWarning("pob", warning)
	end
	return {
		valid = #errors == 0,
		errors = errors,
		warnings = warnings,
		points = points,
		unique_count = uniqueCount,
		constraints = self:getConstraints(),
	}
end

function Api:planAllocation(nodes)
	local build = self:getBuild()
	local added = {}
	local seen = {}
	local unreachable = {}
	local mainCost = 0
	local ascendancyCost = 0
	local secondaryCost = 0
	for _, node in ipairs(nodes) do
		if not node.alloc then
			if not node.path then
				unreachable[#unreachable + 1] = {
					id = node.id,
					name = node.dn or node.name,
				}
			else
				for _, pathNode in ipairs(node.path) do
					if not pathNode.alloc and not seen[pathNode.id] then
						seen[pathNode.id] = true
						added[#added + 1] = {
							id = pathNode.id,
							name = pathNode.dn or pathNode.name,
							type = pathNode.type,
						}
						if pathNode.ascendancyName then
							if not pathNode.isMultipleChoiceOption then
								if build.spec.tree.secondaryAscendNameMap and build.spec.tree.secondaryAscendNameMap[pathNode.ascendancyName] then
									secondaryCost = secondaryCost + 1
								else
									ascendancyCost = ascendancyCost + 1
								end
							end
						else
							mainCost = mainCost + 1
						end
					end
				end
			end
		end
	end
	table.sort(added, function(a, b)
		return a.id < b.id
	end)
	local points = self:pointBudget()
	return {
		added = added,
		cost = #added,
		main_cost = mainCost,
		ascendancy_cost = ascendancyCost,
		secondary_ascendancy_cost = secondaryCost,
		unreachable = unreachable,
		points = {
			used = points.used,
			after = points.used + mainCost,
			max = points.max,
			remaining = points.unspent - mainCost,
			ascendancy_used = points.ascendancy_used,
			ascendancy_max = points.ascendancy_max,
			secondary_ascendancy_used = points.secondary_ascendancy_used,
			secondary_ascendancy_max = points.secondary_ascendancy_max,
		},
		within_budget = points.used + mainCost <= points.max
			and points.ascendancy_used + ascendancyCost <= points.ascendancy_max
			and points.secondary_ascendancy_used + secondaryCost <= points.secondary_ascendancy_max,
	}
end

function Api:summary()
	local build = self:getBuild()
	return {
		name = build.buildName,
		class = build.spec.curClassName,
		ascendancy = build.spec.curAscendClassName,
		level = build.characterLevel,
		tree_version = build.spec.treeVersion,
		points = self:points(build),
		main_skill = self:mainSkillInfo(build),
		stats = objectMap(self:curatedStats(build.calcsTab.mainOutput or {})),
		warnings = self:warnings(build),
		item_count = build.itemsTab and #build.itemsTab.itemOrderList or 0,
		skill_group_count = build.skillsTab and #build.skillsTab.socketGroupList or 0,
	}
end

function Api:metaInfo()
	local build = self:getBuild()
	local gems = build.data and build.data.gems or {}
	local bases = build.data and build.data.itemBases or {}
	local uniqueCount = 0
	for _ in pairs(self.env.main.uniqueDB.list or {}) do
		uniqueCount = uniqueCount + 1
	end
	local gemCount = 0
	for _ in pairs(gems) do
		gemCount = gemCount + 1
	end
	local baseCount = 0
	for _ in pairs(bases) do
		baseCount = baseCount + 1
	end
	return {
		pob = {
			version = self.env.launch.versionNumber,
			branch = self.env.launch.versionBranch,
		},
		tree = {
			latest = latestTreeVersion,
			current = build.spec.treeVersion,
		},
		classes = self:classList(),
		data = {
			gems = gemCount,
			uniques = uniqueCount,
			bases = baseCount,
		},
	}
end

function Api:newBuild(options)
	options = options or {}
	self.env.main:SetMode("BUILD", false, options.name or "MCP Build")
	self.env.runCallback("OnFrame")
	self:checkPrompt()
	local build = self:getBuild()
	self.constraints = {
		level = nil,
		max_points = nil,
		no_uniques = false,
		enforce_points = false,
	}
	self:applyCharacter(build, options)
	if options.level ~= nil then
		self.constraints.level = build.characterLevel
		self.constraints.enforce_points = true
	end
	self:frame()
	return self:summary()
end

function Api:loadXML(xml, name, convert)
	if type(xml) ~= "string" or #xml == 0 then
		error("Build XML is empty", 0)
	end
	self.constraints = {
		level = nil,
		max_points = nil,
		no_uniques = false,
		enforce_points = false,
	}
	self.env.main:SetMode("BUILD", false, name or "Imported Build", xml, convert ~= false)
	self:frame()
	return self:summary()
end

function Api:importBuild(options)
	options = options or {}
	local xml = options.xml
	if not xml and options.code then
		local decoded, err = codec.decodeBuildCode(options.code)
		if not decoded then
			error("Could not decode build code: " .. tostring(err), 0)
		end
		xml = decoded
	end
	if not xml and options.path then
		local resolvedPath = self:resolvePath(options.path)
		local file, err = io.open(resolvedPath, "rb")
		if not file then
			error("Could not open build file: " .. tostring(err), 0)
		end
		xml = file:read("*a")
		file:close()
	end
	if not xml then
		error("build_import requires xml, code, or path", 0)
	end
	local previousXml
	local build = self:getBuild()
	if build and build.SaveDB then
		local ok, value = pcall(build.SaveDB, build, "previous")
		if ok then
			previousXml = value
		end
	end
	local ok, result = pcall(self.loadXML, self, xml, options.name, options.convert)
	if not ok then
		if previousXml then
			self.env.main.popups = {}
			pcall(self.loadXML, self, previousXml, "Recovered Build", true)
		end
		error(result, 0)
	end
	return result
end

function Api:exportBuild(options)
	options = options or {}
	local build = self:getBuild()
	local xml = build:SaveDB("export")
	if not xml then
		error("PoB failed to serialize the build", 0)
	end
	local format = options.format or "xml"
	local data
	if format == "code" then
		local encoded, err = codec.encodeBuildCode(xml)
		if not encoded then
			error("Could not encode build code: " .. tostring(err), 0)
		end
		data = encoded
	elseif format == "xml" then
		data = xml
	else
		error("Unknown export format '" .. tostring(format) .. "'; use xml or code", 0)
	end
	local resolvedPath
	if options.path then
		resolvedPath = self:resolvePath(options.path)
		local file, err = io.open(resolvedPath, "wb")
		if not file then
			error("Could not open export path: " .. tostring(err), 0)
		end
		local written, writeError = file:write(data)
		if not written then
			file:close()
			error("Could not write export path: " .. tostring(writeError), 0)
		end
		local closed, closeError = file:close()
		if not closed then
			error("Could not close export path: " .. tostring(closeError), 0)
		end
	end
	return {
		format = format,
		bytes = #data,
		data = data,
		path = resolvedPath,
	}
end

function Api:snapshot(options)
	options = options or {}
	local name = options.name
	if not name or name == "" then
		self.snapshotCounter = self.snapshotCounter + 1
		name = "snapshot-" .. self.snapshotCounter
	end
	local build = self:getBuild()
	local xml = build:SaveDB("snapshot")
	if not xml then
		error("PoB failed to serialize the build", 0)
	end
	self.snapshots[name] = xml
	self.snapshotConstraints[name] = self:getConstraints()
	local result = {
		name = name,
		bytes = #xml,
	}
	if options.persistent then
		local path = self:snapshotPath(name)
		writeFileAtomic(path, xml)
		writeFileAtomic(self:snapshotMetaPath(name), self:serialiseSnapshotMeta(name, build))
		result.persistent = true
		result.path = path
	end
	return result
end

function Api:restore(options)
	options = options or {}
	local name = options.name
	local xml
	local savedConstraints
	if name and options.persistent then
		local file, err = io.open(self:snapshotPath(name), "rb")
		if not file then
			if self.snapshots[name] then
				xml = self.snapshots[name]
				savedConstraints = self.snapshotConstraints[name] or self:getConstraints()
			else
				error("Unknown persistent snapshot '" .. tostring(name) .. "': " .. tostring(err), 0)
			end
		else
			xml = file:read("*a")
			file:close()
			local metaFile = io.open(self:snapshotMetaPath(name), "rb")
			local meta = metaFile and self:parseSnapshotMeta(metaFile:read("*a")) or {}
			if metaFile then
				metaFile:close()
			end
			savedConstraints = {
				level = meta.level,
				max_points = meta.max_points,
				no_uniques = meta.no_uniques == true,
				enforce_points = meta.enforce_points == true,
			}
			self.snapshots[name] = xml
			self.snapshotConstraints[name] = savedConstraints
		end
	elseif name and self.snapshots[name] then
		xml = self.snapshots[name]
		savedConstraints = self.snapshotConstraints[name] or self:getConstraints()
	else
		error("Unknown snapshot '" .. tostring(name) .. "'", 0)
	end
	local ok, result = pcall(self.importBuild, self, { xml = xml, name = "Snapshot " .. tostring(name), convert = false })
	self.constraints = savedConstraints
	if not ok then
		error(result, 0)
	end
	return result
end


function Api:buildRoot()
	local root = self.env.main.buildPath
	if not root or root == "" then
		error("No build path is configured", 0)
	end
	ensureDir(root)
	return root
end

function Api:resolveBuildPath(options)
	options = options or {}
	local root = self:buildRoot()
	if options.path then
		local path = options.path
		if not (path:match("^[/\\]") or path:match("^%a:[/\\]")) then
			path = root .. path
		end
		if path:find("%.%.") or path:sub(1, #root) ~= root then
			error("Build path must stay inside the build directory", 0)
		end
		return path
	end
	local name = normaliseBuildName(options.name)
	local subPath = options.sub_path and tostring(options.sub_path) or ""
	if subPath ~= "" then
		if subPath:find("%.%.") or subPath:find("^[/\\]") then
			error("Invalid sub_path", 0)
		end
		subPath = subPath:gsub("[/\\]+$", "") .. "/"
		ensureDir(root .. subPath:gsub("/$", ""))
	end
	return root .. subPath .. name .. ".xml"
end

function Api:buildList(options)
	options = options or {}
	local root = self:buildRoot()
	local query = util.lower(util.trim(tostring(options.query or "")))
	local subPath = options.sub_path and tostring(options.sub_path) or ""
	if subPath ~= "" and (subPath:find("%.%.") or subPath:find("^[/\\]")) then
		error("Invalid sub_path", 0)
	end
	local directory = root .. (subPath ~= "" and (subPath:gsub("[/\\]+$", "") .. "/") or "")
	local files = {}
	for _, fullPath in ipairs(listXmlFiles(directory)) do
		local relative = fullPath:sub(#root + 1)
		local relativeDir = relative:match("^(.*)/[^/]+$") or ""
		local fileName = relative:match("([^/]+)$") or relative
		local name = fileName:gsub("%.xml$", "")
		local header = readBuildHeader(fullPath) or {}
		local haystack = util.lower(table.concat({ name, relativeDir, header.className or "", header.ascendClassName or "" }, " "))
		if query == "" or haystack:find(query, 1, true) then
			files[#files + 1] = {
				name = name,
				path = relative,
				class = header.className,
				ascendancy = header.ascendClassName,
				level = header.level,
				active = fullPath == self:activeBuildPath(),
			}
		end
	end
	table.sort(files, function(a, b)
		return util.lower(a.name) < util.lower(b.name)
	end)
	return {
		root = root,
		total = #files,
		builds = files,
	}
end

function Api:activeBuildPath()
	local build = self:getBuild()
	return build and build.dbFileName or nil
end

function Api:buildLoad(options)
	options = options or {}
	local path = self:resolveBuildPath(options)
	local file, err = io.open(path, "rb")
	if not file then
		error("Could not open build '" .. path .. "': " .. tostring(err), 0)
	end
	local xml = file:read("*a")
	file:close()
	local name = options.name and normaliseBuildName(options.name) or path:match("([^/]+)%.xml$") or "Build"
	local summary = self:loadXML(xml, name, options.convert ~= false)
	summary.path = path
	return summary
end

function Api:buildRename(options)
	options = options or {}
	local source = self:resolveBuildPath(options)
	if not options.new_name then
		error("build_rename requires new_name", 0)
	end
	local destinationSubPath = options.sub_path
	if destinationSubPath == nil and options.path ~= nil then
		local root = self:buildRoot()
		local relative = source:sub(#root + 1)
		destinationSubPath = relative:match("^(.*)/[^/]+$")
	end
	local destination = self:resolveBuildPath({ name = options.new_name, sub_path = destinationSubPath })
	if source == destination then
		error("Source and destination are the same", 0)
	end
	if not options.overwrite then
		local existing = io.open(destination, "rb")
		if existing then
			existing:close()
			error("Destination build already exists: " .. destination, 0)
		end
	end
	local renamed, err = os.rename(source, destination)
	if not renamed then
		error("Could not rename build: " .. tostring(err), 0)
	end
	local build = self:getBuild()
	if build and build.dbFileName == source then
		build.dbFileName = destination
		build.name = normaliseBuildName(options.new_name)
	end
	return {
		from = source,
		to = destination,
		name = normaliseBuildName(options.new_name),
	}
end

function Api:buildFork(options)
	options = options or {}
	if not options.new_name then
		error("build_fork requires new_name", 0)
	end
	local xml
	local source
	if options.path or options.name then
		source = self:resolveBuildPath(options)
		local file, err = io.open(source, "rb")
		if not file then
			error("Could not open build '" .. source .. "': " .. tostring(err), 0)
		end
		xml = file:read("*a")
		file:close()
	else
		local build = self:getBuild()
		xml = build:SaveDB("fork")
		if not xml then
			error("PoB failed to serialize the build", 0)
		end
	end
	local destination = self:resolveBuildPath({ name = options.new_name, sub_path = options.sub_path })
	if not options.overwrite then
		local existing = io.open(destination, "rb")
		if existing then
			existing:close()
			error("Destination build already exists: " .. destination, 0)
		end
	end
	writeFileAtomic(destination, xml)
	local result = {
		from = source,
		to = destination,
		name = normaliseBuildName(options.new_name),
	}
	if options.switch ~= false then
		result.build = self:loadXML(xml, result.name, true)
		result.build.path = destination
	end
	return result
end

function Api:buildDelete(options)
	options = options or {}
	local path = self:resolveBuildPath(options)
	if path == self:activeBuildPath() then
		error("Cannot delete the active build; load another build first", 0)
	end
	local removed, err = os.remove(path)
	if not removed then
		error("Could not delete build: " .. tostring(err), 0)
	end
	return { path = path, deleted = true }
end

function Api:snapshotsDir()
	local directory = self.env.main.userPath .. "MCP/Snapshots/"
	ensureDir(self.env.main.userPath .. "MCP")
	ensureDir(directory)
	return directory
end

function Api:snapshotMetaPath(name)
	return self:snapshotsDir() .. normaliseBuildName(name) .. ".meta"
end

function Api:snapshotPath(name)
	return self:snapshotsDir() .. normaliseBuildName(name) .. ".xml"
end

function Api:serialiseSnapshotMeta(name, build)
	local constraints = self:getConstraints()
	local lines = {
		"name=" .. tostring(name):gsub("[\r\n]", " "),
		"level=" .. tostring(constraints.level or ""),
		"max_points=" .. tostring(constraints.max_points or ""),
		"no_uniques=" .. tostring(constraints.no_uniques and true or false),
		"enforce_points=" .. tostring(constraints.enforce_points and true or false),
		"tree=" .. tostring(build.treeVersion or build.spec.treeVersion or ""),
	}
	return table.concat(lines, "\n") .. "\n"
end

function Api:parseSnapshotMeta(text)
	local meta = {}
	for line in tostring(text or ""):gmatch("[^\n]+") do
		local key, value = line:match("^([^=]+)=(.*)$")
		if key then
			meta[key] = value
		end
	end
	meta.level = meta.level and tonumber(meta.level) or nil
	meta.max_points = meta.max_points and tonumber(meta.max_points) or nil
	meta.no_uniques = meta.no_uniques == "true"
	meta.enforce_points = meta.enforce_points == "true"
	return meta
end

function Api:persistentSnapshots()
	local directory = self:snapshotsDir()
	local snapshots = {}
	for _, path in ipairs(listXmlFiles(directory)) do
		local name = path:match("([^/]+)%.xml$")
		if name and not path:sub(#directory + 1):find("/") then
			local metaFile = io.open(directory .. name .. ".meta", "rb")
			local meta = metaFile and self:parseSnapshotMeta(metaFile:read("*a")) or {}
			if metaFile then
				metaFile:close()
			end
			snapshots[#snapshots + 1] = {
				name = name,
				path = path,
				level = meta.level,
				constraints = meta,
			}
		end
	end
	table.sort(snapshots, function(a, b)
		return a.name < b.name
	end)
	return snapshots
end

function Api:snapshotList(options)
	options = options or {}
	local snapshots = {}
	local byName = {}
	for name in pairs(self.snapshots) do
		byName[name] = { name = name, persistent = false }
	end
	for _, entry in ipairs(self:persistentSnapshots()) do
		byName[entry.name] = {
			name = entry.name,
			persistent = true,
			path = entry.path,
			level = entry.level,
			constraints = entry.constraints,
		}
	end
	for _, entry in pairs(byName) do
		snapshots[#snapshots + 1] = entry
	end
	table.sort(snapshots, function(a, b)
		return a.name < b.name
	end)
	return {
		total = #snapshots,
		snapshots = snapshots,
	}
end

function Api:snapshotDelete(options)
	options = options or {}
	if not options.name then
		error("snapshot_delete requires name", 0)
	end
	local name = options.name
	local xmlPath = self:snapshotPath(name)
	local metaPath = self:snapshotMetaPath(name)
	local file = io.open(xmlPath, "rb")
	local persisted = file ~= nil
	if file then
		file:close()
		local removed, err = os.remove(xmlPath)
		if not removed then
			error("Could not delete persistent snapshot: " .. tostring(err), 0)
		end
	end
	os.remove(metaPath)
	local inMemory = self.snapshots[name] ~= nil
	if not persisted and not inMemory then
		error("Unknown snapshot '" .. tostring(name) .. "'", 0)
	end
	self.snapshots[name] = nil
	self.snapshotConstraints[name] = nil
	return {
		name = name,
		deleted = true,
		persistent = persisted,
		memory = inMemory,
	}
end

function Api:characterSet(options)
	options = options or {}
	local build = self:getBuild()
	self:applyCharacter(build, options)
	if options.level ~= nil then
		self.constraints.level = build.characterLevel
		self.constraints.enforce_points = true
	end
	self:frame()
	return self:summary()
end

function Api:nodeMatchesType(node, nodeType)
	if not nodeType then
		return true
	end
	nodeType = util.lower(nodeType)
	if nodeType == "all" then
		return true
	elseif nodeType == "ascendancy" then
		return node.ascendancyName ~= nil
	elseif nodeType == "notable" then
		return node.type == "Notable"
	elseif nodeType == "keystone" then
		return node.type == "Keystone"
	elseif nodeType == "mastery" then
		return node.type == "Mastery"
	elseif nodeType == "socket" then
		return node.type == "Socket"
	elseif nodeType == "normal" then
		return node.type == "Normal"
	end
	return true
end

function Api:nodeResult(node)
	local stats = {}
	for index, line in ipairs(node.sd or {}) do
		stats[index] = util.stripColors(line)
	end
	local pathCost = node.pathDist
	if pathCost == nil or pathCost >= 1000 then
		pathCost = nil
	end
	local result = {
		id = node.id,
		name = node.dn or node.name,
		type = node.type,
		stats = stats,
		ascendancy = node.ascendancyName,
		allocated = node.alloc == true,
		path_cost = pathCost,
		keystone = node.type == "Keystone" or nil,
		notable = node.type == "Notable" or nil,
		mastery = node.type == "Mastery" or nil,
		socket = node.type == "Socket" or nil,
	}
	if node.type == "Mastery" then
		local effects = {}
		for _, entry in ipairs(node.masteryEffects or {}) do
			local effectId = entry.effect
			local effect = self:getBuild().spec.tree.masteryEffects[effectId]
			if effect then
				effects[#effects + 1] = {
					id = effectId,
					stats = util.sanitize(effect.sd or {}, { depth = 3 }),
				}
			end
		end
		result.mastery_effects = effects
	end
	return result
end

function Api:passivesSearch(options)
	options = options or {}
	local build = self:getBuild()
	local query = util.lower(util.trim(tostring(options.query or "")))
	local nodeType = options.type
	local ascendancy = options.ascendancy and util.lower(tostring(options.ascendancy)) or nil
	local allocatedFilter = options.allocated
	local reachableFilter = options.reachable
	local limit = util.clamp(tonumber(options.limit) or 20, 1, 100)
	local offset = math.max(0, tonumber(options.offset) or 0)
	local matches = {}
	for _, node in pairs(build.spec.nodes) do
		if node.type ~= "ClassStart" and node.type ~= "AscendClassStart" then
			local include = self:nodeMatchesType(node, nodeType)
			if include and ascendancy then
				include = node.ascendancyName ~= nil and util.lower(node.ascendancyName) == ascendancy
			end
			if include and allocatedFilter ~= nil then
				include = (node.alloc == true) == (allocatedFilter == true)
			end
			if include and reachableFilter == true then
				include = node.pathDist ~= nil and node.pathDist < 1000
			end
			if include and query ~= "" then
				local searchable = util.lower(table.concat({ node.dn or "", node.type or "", node.ascendancyName or "", table.concat(node.sd or {}, "\n") }, "\n"))
				include = searchable:find(query, 1, true) ~= nil
			end
			if include then
				matches[#matches + 1] = node
			end
		end
	end
	table.sort(matches, function(a, b)
		local aCost = (a.pathDist ~= nil and a.pathDist < 1000) and a.pathDist or 10000
		local bCost = (b.pathDist ~= nil and b.pathDist < 1000) and b.pathDist or 10000
		if aCost ~= bCost then
			return aCost < bCost
		end
		local aName = util.lower(a.dn or a.name or "")
		local bName = util.lower(b.dn or b.name or "")
		if aName ~= bName then
			return aName < bName
		end
		return a.id < b.id
	end)
	local output = {}
	for index = offset + 1, math.min(#matches, offset + limit) do
		output[#output + 1] = self:nodeResult(matches[index])
	end
	return {
		total = #matches,
		offset = offset,
		limit = limit,
		nodes = output,
	}
end

function Api:passivesGet()
	local build = self:getBuild()
	local allocated = {}
	for _, node in pairs(build.spec.allocNodes) do
		if node.type ~= "ClassStart" and node.type ~= "AscendClassStart" then
			allocated[#allocated + 1] = {
				id = node.id,
				name = node.dn or node.name,
				type = node.type,
				ascendancy = node.ascendancyName,
			}
		end
	end
	table.sort(allocated, function(a, b)
		return a.id < b.id
	end)
	local masteries = {}
	for nodeId, effectId in pairs(build.spec.masterySelections) do
		local effect = build.spec.tree.masteryEffects[effectId]
		masteries[#masteries + 1] = {
			node_id = nodeId,
			effect_id = effectId,
			stats = effect and util.sanitize(effect.sd or {}, { depth = 3 }) or nil,
		}
	end
	return {
		tree_version = build.spec.treeVersion,
		points = self:points(build),
		allocated = allocated,
		mastery_selections = masteries,
	}
end

function Api:resolveNodes(options)
	local build = self:getBuild()
	local nodes = {}
	local errors = {}
	local seen = {}
	if options.ids then
		for _, idValue in ipairs(options.ids) do
			local id = tonumber(idValue)
			local node = id and build.spec.nodes[id]
			if node and not seen[node.id] then
				seen[node.id] = true
				nodes[#nodes + 1] = node
			elseif not node then
				errors[#errors + 1] = "Unknown node id '" .. tostring(idValue) .. "'"
			end
		end
	end
	if options.names then
		for _, nameValue in ipairs(options.names) do
			local target = util.lower(util.trim(tostring(nameValue)))
			local matches = {}
			for _, node in pairs(build.spec.nodes) do
				if util.lower(node.dn or node.name or "") == target then
					matches[#matches + 1] = node
				end
			end
			table.sort(matches, function(a, b)
				return a.id < b.id
			end)
			if #matches > 1 then
				local ids = {}
				for _, node in ipairs(matches) do
					ids[#ids + 1] = tostring(node.id)
				end
				errors[#errors + 1] = "Node name '" .. tostring(nameValue) .. "' is ambiguous; use one of these ids: " .. table.concat(ids, ", ")
			elseif #matches == 1 then
				local found = matches[1]
				if not seen[found.id] then
					seen[found.id] = true
					nodes[#nodes + 1] = found
				end
			else
				errors[#errors + 1] = "Unknown node name '" .. tostring(nameValue) .. "'"
			end
		end
	end
	return nodes, errors
end

function Api:applyMasteryEffect(node, effectId)
	local build = self:getBuild()
	if node.type ~= "Mastery" then
		error("Node '" .. tostring(node.dn or node.name) .. "' is not a mastery", 0)
	end
	if not node.alloc and not node.path then
		error("Mastery node '" .. tostring(node.dn or node.name) .. "' is unreachable", 0)
	end
	local effect = build.spec.tree.masteryEffects[effectId]
	if not effect then
		error("Unknown mastery effect '" .. tostring(effectId) .. "'", 0)
	end
	for nodeId, selectedEffectId in pairs(build.spec.masterySelections) do
		if selectedEffectId == effectId and nodeId ~= node.id and build.spec.allocNodes[nodeId] then
			error("Mastery effect '" .. tostring(effectId) .. "' is already selected at node " .. tostring(nodeId), 0)
		end
	end
	if node.masteryEffects and #node.masteryEffects > 0 then
		local valid = false
		for _, entry in ipairs(node.masteryEffects) do
			if entry.effect == effectId then
				valid = true
				break
			end
		end
		if not valid then
			error("Mastery effect '" .. tostring(effectId) .. "' is not available on '" .. tostring(node.dn or node.name) .. "'", 0)
		end
	end
	node.sd = effect.sd
	node.allMasteryOptions = false
	node.reminderText = { "Tip: Right click to select a different effect" }
	build.spec.tree:ProcessStats(node)
	build.spec.masterySelections[node.id] = effectId
	if not node.alloc then
		if not node.path then
			error("Mastery node '" .. tostring(node.dn or node.name) .. "' is unreachable", 0)
		end
		build.spec:AllocNode(node)
	end
end

function Api:passivesPlan(options)
	options = options or {}
	local nodes, errors = self:resolveNodes(options)
	if #nodes == 0 then
		error(#errors > 0 and table.concat(errors, "; ") or "No nodes supplied", 0)
	end
	local plan = self:planAllocation(nodes)
	plan.errors = errors
	plan.mastery_required = {}
	for _, node in ipairs(nodes) do
		if not node.alloc and node.type == "Mastery" then
			plan.mastery_required[#plan.mastery_required + 1] = {
				id = node.id,
				name = node.dn or node.name,
			}
		end
	end
	return plan
end

function Api:passivesAllocate(options)
	options = options or {}
	local build = self:getBuild()
	local nodes, errors = self:resolveNodes(options)
	if #nodes == 0 then
		error(#errors > 0 and table.concat(errors, "; ") or "No nodes supplied", 0)
	end
	local plan = self:planAllocation(nodes)
	if self.constraints.enforce_points and not plan.within_budget and options.allow_over_budget ~= true then
		error(string.format("Point budget exceeded: allocation adds %d main points and %d ascendancy points, putting the build at %d/%d main and %d/8 ascendancy", plan.main_cost, plan.ascendancy_cost + plan.secondary_ascendancy_cost, plan.points.after, plan.points.max, plan.points.ascendancy_used + plan.ascendancy_cost + plan.secondary_ascendancy_cost), 0)
	end
	local masteryEffects = {}
	for key, value in pairs(options.mastery_effects or {}) do
		local nodeId = tonumber(key)
		local effectId = tonumber(value)
		if nodeId and effectId then
			masteryEffects[nodeId] = effectId
		end
	end
	local before = {}
	for id in pairs(build.spec.allocNodes) do
		before[id] = true
	end
	for _, node in ipairs(nodes) do
		if not node.alloc then
			local effectId = masteryEffects[node.id]
			local ok, err = pcall(function()
				if effectId then
					self:applyMasteryEffect(node, effectId)
				elseif node.type == "Mastery" then
					error("Mastery node '" .. tostring(node.dn or node.name) .. "' requires a mastery_effects entry", 0)
				elseif not node.path then
					error("Node '" .. tostring(node.dn or node.name) .. "' is unreachable", 0)
				else
					build.spec:AllocNode(node)
				end
			end)
			if not ok then
				errors[#errors + 1] = util.summaryLine(err)
			end
		end
	end
	self:frame()
	local added = {}
	for id, node in pairs(build.spec.allocNodes) do
		if not before[id] and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" then
			added[#added + 1] = {
				id = node.id,
				name = node.dn or node.name,
				type = node.type,
			}
		end
	end
	table.sort(added, function(a, b)
		return a.id < b.id
	end)
	return {
		added = added,
		errors = errors,
		points = self:points(build),
		plan = plan,
		state = self:passivesGet(),
	}
end

function Api:passivesDeallocate(options)
	options = options or {}
	local build = self:getBuild()
	local nodes, errors = self:resolveNodes(options)
	if #nodes == 0 then
		error(#errors > 0 and table.concat(errors, "; ") or "No nodes supplied", 0)
	end
	local before = {}
	for id in pairs(build.spec.allocNodes) do
		before[id] = true
	end
	for _, node in ipairs(nodes) do
		if node.alloc then
			local ok, err = pcall(function()
				build.spec:DeallocNode(node)
			end)
			if not ok then
				errors[#errors + 1] = util.summaryLine(err)
			end
		end
	end
	self:frame()
	local removed = {}
	for id in pairs(before) do
		if not build.spec.allocNodes[id] then
			local node = build.spec.nodes[id]
			removed[#removed + 1] = {
				id = id,
				name = node and (node.dn or node.name) or nil,
				type = node and node.type or nil,
			}
		end
	end
	table.sort(removed, function(a, b)
		return a.id < b.id
	end)
	return {
		removed = removed,
		errors = errors,
		points = self:points(build),
		state = self:passivesGet(),
	}
end

function Api:passivesSetMastery(options)
	options = options or {}
	local build = self:getBuild()
	local nodeId = tonumber(options.node_id)
	local effectId = tonumber(options.effect_id)
	if not nodeId or not effectId then
		error("node_id and effect_id are required", 0)
	end
	local node = build.spec.nodes[nodeId]
	if not node then
		error("Unknown node id '" .. tostring(nodeId) .. "'", 0)
	end
	if node.type ~= "Mastery" then
		error("Node '" .. tostring(node.dn or node.name) .. "' is not a mastery", 0)
	end
	self:applyMasteryEffect(node, effectId)
	self:frame()
	return {
		node_id = nodeId,
		effect_id = effectId,
		state = self:passivesGet(),
	}
end

function Api:gems()
	return self:getBuild().data.gems
end

function Api:skillsSearch(options)
	options = options or {}
	local query = util.lower(util.trim(tostring(options.query or "")))
	local kind = options.kind and util.lower(tostring(options.kind)) or nil
	local tagFilters = {}
	if type(options.tags) == "table" then
		for _, tag in ipairs(options.tags) do
			tagFilters[#tagFilters + 1] = util.lower(tostring(tag))
		end
	elseif type(options.tags) == "string" then
		for tag in options.tags:gmatch("[^,]+") do
			tagFilters[#tagFilters + 1] = util.lower(util.trim(tag))
		end
	end
	local limit = util.clamp(tonumber(options.limit) or 20, 1, 100)
	local offset = math.max(0, tonumber(options.offset) or 0)
	local byName = {}
	for _, gem in pairs(self:gems()) do
		local include = true
		if kind == "support" then
			include = gem.tags and gem.tags.support == true
		elseif kind == "active" then
			include = not (gem.tags and gem.tags.support == true)
		end
		if include and query ~= "" then
			local searchable = util.lower((gem.name or "") .. "\n" .. (gem.tagString or ""))
			include = searchable:find(query, 1, true) ~= nil
		end
		if include and #tagFilters > 0 then
			for _, tag in ipairs(tagFilters) do
				if not (gem.tags and gem.tags[tag] == true) then
					include = false
					break
				end
			end
		end
		if include then
			local existing = byName[gem.name]
			if not existing or ((gem.naturalMaxLevel or 0) > (existing.naturalMaxLevel or 0)) then
				byName[gem.name] = gem
			end
		end
	end
	local names = util.sortedPairsKeys(byName)
	local output = {}
	for index = offset + 1, math.min(#names, offset + limit) do
		local gem = byName[names[index]]
		output[#output + 1] = {
			name = gem.name,
			tag_string = gem.tagString,
			support = gem.tags and gem.tags.support == true or false,
			vaal = gem.tags and gem.tags.vaal == true or false,
			awakened = gem.tags and gem.tags.awakened == true or false,
			max_level = gem.naturalMaxLevel,
			requirement = {
				str = gem.reqStr or 0,
				dex = gem.reqDex or 0,
				int = gem.reqInt or 0,
			},
		}
	end
	return {
		total = #names,
		offset = offset,
		limit = limit,
		gems = output,
	}
end

function Api:findGem(name)
	local target = util.lower(util.trim(tostring(name or "")))
	if target == "" then
		return nil, "Gem name is empty"
	end
	local build = self:getBuild()
	local best
	for _, gem in pairs(build.data.gems) do
		if util.lower(gem.name or "") == target then
			if not best or (gem.naturalMaxLevel or 0) > (best.naturalMaxLevel or 0) then
				best = gem
			end
		end
	end
	if best then
		return best
	end
	local ok, err, gemData = pcall(build.skillsTab.FindSkillGem, build.skillsTab, name)
	if not ok then
		return nil, tostring(err)
	end
	if err then
		return nil, err
	end
	return gemData
end

function Api:resolveEditableSkillGroup(value)
	local index = tonumber(value)
	local group = index and self:getBuild().skillsTab.socketGroupList[index]
	if not group then
		error("Unknown skill group '" .. tostring(value) .. "'", 0)
	end
	if group.source then
		error("Skill groups granted by items or the tree cannot be edited", 0)
	end
	return group, index
end

function Api:makeGemInstance(gemInput)
	local name = gemInput.name
	if type(name) ~= "string" or name == "" then
		error("Every gem needs a name", 0)
	end
	local gemData, err = self:findGem(name)
	if not gemData then
		error(err, 0)
	end
	return {
		nameSpec = gemData.name,
		gemId = gemData.id,
		skillId = gemData.grantedEffectId,
		level = util.clamp(math.floor(tonumber(gemInput.level) or 20), 1, 40),
		quality = util.clamp(math.floor(tonumber(gemInput.quality) or 0), 0, 100),
		enabled = gemInput.enabled ~= false,
		count = math.max(1, math.floor(tonumber(gemInput.count) or 1)),
		enableGlobal1 = gemInput.enable_global_1 ~= false,
		enableGlobal2 = gemInput.enable_global_2 ~= false,
	}
end

function Api:clampSkillGroupIndexes(group)
	local skillList = group.displaySkillList or {}
	group.mainActiveSkill = util.clamp(math.floor(tonumber(group.mainActiveSkill) or 1), 1, math.max(1, #skillList))
	local calcsList = group.displaySkillListCalcs or skillList
	group.mainActiveSkillCalcs = util.clamp(math.floor(tonumber(group.mainActiveSkillCalcs) or group.mainActiveSkill), 1, math.max(1, #calcsList))
end

function Api:skillSlotDiagnostics(group)
	local build = self:getBuild()
	local slot = group.slot
	if not slot then
		return nil
	end
	local slotControl = build.itemsTab.slots[slot]
	local item = slotControl and build.itemsTab.items[slotControl.selItemId]
	if not item then
		return {
			slot = slot,
			item_id = nil,
			item_name = nil,
			sockets = nil,
		}
	end
	local info = socketInfo(item)
	info.slot = slot
	info.item_id = item.id
	info.item_name = item.name or item.baseName
	info.socket_string = socketString(item)
	info.groups = {}
	local offset = 0
	for index, other in ipairs(build.skillsTab.socketGroupList) do
		if other.slot == slot then
			if other == group then
				local colors = {}
				local mismatches = {}
				local socketIndex = 0
				for _, gem in ipairs(group.gemList or {}) do
					if gem.gemData or gem.grantedEffect then
						socketIndex = socketIndex + 1
						local granted = gem.grantedEffect or gem.gemData.grantedEffect
						local color = granted and granted.color
						local expected = color == 1 and "R" or color == 2 and "G" or color == 3 and "B" or "W"
						local socket = item.sockets and item.sockets[offset + socketIndex]
						colors[#colors + 1] = {
							gem = gem.nameSpec or (gem.gemData and gem.gemData.name),
							expected = expected,
							actual = socket and socket.color or nil,
							matches = socket and (item.sockets.colourAlwaysMatches or socket.color == expected) or false,
						}
						if socket and not (item.sockets.colourAlwaysMatches or socket.color == expected) then
							mismatches[#mismatches + 1] = expected .. "->" .. socket.color
						end
					end
				end
				info.groups[#info.groups + 1] = {
					index = index,
					offset = offset,
					colors = colors,
					mismatches = mismatches,
				}
				break
			end
			offset = offset + #(other.gemList or {})
		end
	end
	return info
end

function Api:skillsGet()
	local build = self:getBuild()
	local output = {}
	for index, group in ipairs(build.skillsTab.socketGroupList) do
		local gems = {}
		for _, gem in ipairs(group.gemList or {}) do
			local granted = gem.grantedEffect or (gem.gemData and gem.gemData.grantedEffect)
			gems[#gems + 1] = {
				name = gem.nameSpec or (gem.gemData and gem.gemData.name),
				gem_id = gem.gemData and gem.gemData.id,
				skill_id = gem.skillId,
				level = gem.level,
				quality = gem.quality,
				enabled = gem.enabled ~= false,
				count = gem.count or 1,
				color = granted and (granted.color == 1 and "R" or granted.color == 2 and "G" or granted.color == 3 and "B" or "W") or nil,
				matches_socket = gem.matchesSocket,
				req_level = gem.reqLevel,
				req_str = gem.reqStr,
				req_dex = gem.reqDex,
				req_int = gem.reqInt,
				err_msg = gem.errMsg,
			}
		end
		output[#output + 1] = {
			index = index,
			label = group.label,
			display_label = group.displayLabel,
			slot = group.slot,
			enabled = group.enabled ~= false,
			is_main = index == (build.mainSocketGroup or 1),
			main_active = group.mainActiveSkill or 1,
			main_active_calcs = group.mainActiveSkillCalcs,
			include_in_full_dps = group.includeInFullDPS == true,
			group_count = group.groupCount,
			source = group.source,
			slot_enabled = group.slotEnabled ~= false,
			imbued_support = group.imbuedSupport,
			gems = gems,
			socket_diagnostics = self:skillSlotDiagnostics(group),
		}
	end
	return {
		main_group = build.mainSocketGroup or 1,
		slots = groupSlotOrder,
		groups = output,
	}
end

function Api:skillsAddGroup(options)
	options = options or {}
	local build = self:getBuild()
	local gems = options.gems
	if type(gems) ~= "table" or #gems == 0 then
		error("skills_add_group requires a non-empty gems array", 0)
	end
	if options.slot and options.slot ~= "" and not groupSlots[options.slot] then
		error("Unknown skill group slot '" .. tostring(options.slot) .. "'", 0)
	end
	local hasActive = false
	local group = {
		label = options.label or "",
		slot = options.slot,
		enabled = options.enabled ~= false,
		includeInFullDPS = options.include_in_full_dps == true,
		groupCount = tonumber(options.group_count),
		gemList = {},
		mainActiveSkill = 1,
	}
	for _, gemInput in ipairs(gems) do
		local gem = self:makeGemInstance(gemInput)
		group.gemList[#group.gemList + 1] = gem
		local gemData = self:findGem(gemInput.name)
		if gemData and not (gemData.tags and gemData.tags.support == true) then
			hasActive = true
		end
	end
	local afterCount = #build.skillsTab.socketGroupList + 1
	build.skillsTab.socketGroupList[afterCount] = group
	build.skillsTab:ProcessSocketGroup(group)
	local setMain = options.set_main
	if setMain == nil then
		setMain = hasActive
	end
	if setMain then
		build.mainSocketGroup = afterCount
	end
	self:frame()
	return {
		group_index = afterCount,
		group = self:skillsGet().groups[afterCount],
		state = self:skillsGet(),
	}
end

function Api:skillsUpdateGroup(options)
	options = options or {}
	local build = self:getBuild()
	local group, index = self:resolveEditableSkillGroup(options.group)
	if options.label ~= nil then
		group.label = tostring(options.label)
	end
	if options.enabled ~= nil then
		group.enabled = options.enabled == true
	end
	if options.include_in_full_dps ~= nil then
		group.includeInFullDPS = options.include_in_full_dps == true
	end
	if options.group_count ~= nil then
		group.groupCount = tonumber(options.group_count)
	end
	if options.imbued_support ~= nil then
		if options.imbued_support == "" then
			group.imbuedSupport = nil
		else
			group.imbuedSupport = tostring(options.imbued_support)
		end
	end
	if options.slot ~= nil then
		local slot = options.slot
		if slot == "" or slot == "None" then
			slot = nil
		elseif not groupSlots[slot] then
			error("Unknown skill group slot '" .. tostring(slot) .. "'", 0)
		end
		group.slot = slot
	end
	if options.set_main == true then
		build.mainSocketGroup = index
	end
	build.skillsTab:ProcessSocketGroup(group)
	build.skillsTab:RebuildImbuedSupportBySlot()
	self:frame()
	return self:skillsGet().groups[index]
end

function Api:skillsSetSlot(options)
	options = options or {}
	local group, index = self:resolveEditableSkillGroup(options.group)
	local slot = options.slot
	if slot == "" or slot == "None" then
		slot = nil
	elseif slot ~= nil and not groupSlots[slot] then
		error("Unknown skill group slot '" .. tostring(slot) .. "'", 0)
	end
	group.slot = slot
	self:getBuild().skillsTab:RebuildImbuedSupportBySlot()
	self:frame()
	return self:skillsGet().groups[index]
end

function Api:skillsAddGem(options)
	options = options or {}
	local group, index = self:resolveEditableSkillGroup(options.group)
	local gem = self:makeGemInstance(options.gem or {})
	local position = tonumber(options.position)
	if position then
		table.insert(group.gemList, util.clamp(math.floor(position), 1, #group.gemList + 1), gem)
	else
		group.gemList[#group.gemList + 1] = gem
	end
	self:getBuild().skillsTab:ProcessSocketGroup(group)
	self:clampSkillGroupIndexes(group)
	self:frame()
	return self:skillsGet().groups[index]
end

function Api:skillsRemoveGem(options)
	options = options or {}
	local group, index = self:resolveEditableSkillGroup(options.group)
	local gemIndex = tonumber(options.gem)
	if not gemIndex or not group.gemList[gemIndex] then
		error("Unknown gem index '" .. tostring(options.gem) .. "'", 0)
	end
	table.remove(group.gemList, gemIndex)
	self:getBuild().skillsTab:ProcessSocketGroup(group)
	self:clampSkillGroupIndexes(group)
	self:frame()
	return self:skillsGet().groups[index]
end

function Api:skillsSetGems(options)
	options = options or {}
	local group, index = self:resolveEditableSkillGroup(options.group)
	if type(options.gems) ~= "table" then
		error("skills_set_gems requires a gems array", 0)
	end
	group.gemList = {}
	for _, gemInput in ipairs(options.gems) do
		group.gemList[#group.gemList + 1] = self:makeGemInstance(gemInput)
	end
	self:getBuild().skillsTab:ProcessSocketGroup(group)
	self:clampSkillGroupIndexes(group)
	self:frame()
	return self:skillsGet().groups[index]
end

function Api:skillsRemoveGroup(options)
	options = options or {}
	local build = self:getBuild()
	local groupIndex = tonumber(options.group)
	local group = groupIndex and build.skillsTab.socketGroupList[groupIndex]
	if not group then
		error("Unknown skill group '" .. tostring(options.group) .. "'", 0)
	end
	if group.source then
		error("Skill groups granted by items cannot be removed", 0)
	end
	if build.skillsTab.displayGroup == group then
		build.skillsTab.displayGroup = nil
	end
	table.remove(build.skillsTab.socketGroupList, groupIndex)
	if build.mainSocketGroup == groupIndex then
		build.mainSocketGroup = 1
	elseif build.mainSocketGroup and build.mainSocketGroup > groupIndex then
		build.mainSocketGroup = build.mainSocketGroup - 1
	end
	if build.calcsTab.input.skill_number == groupIndex then
		build.calcsTab.input.skill_number = 1
	elseif build.calcsTab.input.skill_number and build.calcsTab.input.skill_number > groupIndex then
		build.calcsTab.input.skill_number = build.calcsTab.input.skill_number - 1
	end
	build.skillsTab:RebuildImbuedSupportBySlot()
	self:frame()
	return self:skillsGet()
end

function Api:skillsSetMain(options)
	options = options or {}
	local build = self:getBuild()
	local groupIndex = tonumber(options.group)
	local group = groupIndex and build.skillsTab.socketGroupList[groupIndex]
	if not group then
		error("Unknown skill group '" .. tostring(options.group) .. "'", 0)
	end
	build.mainSocketGroup = groupIndex
	local active = tonumber(options.active)
	if active then
		group.mainActiveSkill = util.clamp(math.floor(active), 1, math.max(1, #(group.displaySkillList or {})))
	end
	group.mainActiveSkill = group.mainActiveSkill or 1
	self:frame()
	return self:skillsGet()
end

function Api:findUnique(name)
	local lower = util.lower(util.trim(tostring(name or "")))
	if lower == "" then
		return nil
	end
	local db = self.env.main.uniqueDB
	local item = db.byTitle and db.byTitle[lower]
	if item then
		return item
	end
	for key, candidate in pairs(db.list or {}) do
		if util.lower(key) == lower or util.lower(candidate.title or "") == lower then
			return candidate
		end
	end
	return nil
end

function Api:itemsSearchUniques(options)
	options = options or {}
	local query = util.lower(util.trim(tostring(options.query or "")))
	local slotFilter = options.slot and util.lower(tostring(options.slot)) or nil
	local baseFilter = options.base and util.lower(tostring(options.base)) or nil
	local limit = util.clamp(tonumber(options.limit) or 20, 1, 100)
	local offset = math.max(0, tonumber(options.offset) or 0)
	local includeRaw = options.include_raw == true
	local matches = {}
	for _, item in pairs(self.env.main.uniqueDB.list or {}) do
		local include = true
		if slotFilter then
			local primarySlot = util.lower(item:GetPrimarySlot())
			include = primarySlot == slotFilter or primarySlot:gsub(" %d+$", "") == slotFilter
		end
		if include and baseFilter then
			include = util.lower(item.baseName or "") == baseFilter
		end
		if include and query ~= "" then
			local modLines = {}
			for _, line in ipairs(item.explicitModLines or {}) do
				modLines[#modLines + 1] = line.line
			end
			local searchable = util.lower(table.concat({ item.name or "", item.title or "", item.baseName or "", table.concat(modLines, "\n") }, "\n"))
			include = searchable:find(query, 1, true) ~= nil
		end
		if include then
			matches[#matches + 1] = item
		end
	end
	table.sort(matches, function(a, b)
		return util.lower(a.name or "") < util.lower(b.name or "")
	end)
	local output = {}
	for index = offset + 1, math.min(#matches, offset + limit) do
		local item = matches[index]
		local entry = {
			name = item.name,
			title = item.title,
			base = item.baseName,
			type = item.type,
			primary_slot = item:GetPrimarySlot(),
			variants = item.variantList,
			league = item.league,
		}
		if includeRaw then
			entry.raw = item:BuildRaw()
		end
		output[#output + 1] = entry
	end
	return {
		total = #matches,
		offset = offset,
		limit = limit,
		uniques = output,
	}
end


function Api:itemsSearchTemplates(options)
	options = options or {}
	local query = util.lower(util.trim(tostring(options.query or "")))
	local baseFilter = options.base and util.lower(tostring(options.base)) or nil
	local slotFilter = options.slot and util.lower(tostring(options.slot)) or nil
	local limit = util.clamp(tonumber(options.limit) or 20, 1, 100)
	local offset = math.max(0, tonumber(options.offset) or 0)
	local includeRaw = options.include_raw == true
	local matches = {}
	for _, item in pairs(self.env.main.rareDB.list or {}) do
		local include = true
		if baseFilter then
			include = util.lower(item.baseName or "") == baseFilter
		end
		if include and slotFilter then
			local primarySlot = util.lower(item:GetPrimarySlot())
			include = primarySlot == slotFilter or primarySlot:gsub(" %d+$", "") == slotFilter
		end
		if include and query ~= "" then
			local modLines = {}
			for _, line in ipairs(item.explicitModLines or {}) do
				modLines[#modLines + 1] = line.line
			end
			local searchable = util.lower(table.concat({ item.name or "", item.title or "", item.baseName or "", table.concat(modLines, "\n") }, "\n"))
			include = searchable:find(query, 1, true) ~= nil
		end
		if include then
			matches[#matches + 1] = item
		end
	end
	table.sort(matches, function(a, b)
		return util.lower(a.name or "") < util.lower(b.name or "")
	end)
	local output = {}
	for index = offset + 1, math.min(#matches, offset + limit) do
		local item = matches[index]
		local entry = {
			name = item.name,
			title = item.title,
			base = item.baseName,
			type = item.type,
			primary_slot = item:GetPrimarySlot(),
			item_level = item.itemLevel,
		}
		if includeRaw then
			entry.raw = item:BuildRaw()
		end
		output[#output + 1] = entry
	end
	return {
		total = #matches,
		offset = offset,
		limit = limit,
		templates = output,
	}
end

function Api:itemsAddTemplate(options)
	options = options or {}
	local query = util.lower(util.trim(tostring(options.name or options.title or "")))
	if query == "" then
		error("items_add_template requires name", 0)
	end
	local found
	for _, item in pairs(self.env.main.rareDB.list or {}) do
		if util.lower(item.name or "") == query or util.lower(item.title or "") == query then
			found = item
			break
		end
	end
	if not found then
		error("Unknown rare template '" .. tostring(options.name or options.title) .. "'. Use items_search_templates.", 0)
	end
	return self:itemsAddRaw({
		raw = found:BuildRaw(),
		slot = options.slot,
		equip = options.equip,
		allow_requirement_violation = options.allow_requirement_violation,
	})
end

function Api:itemsSearchBases(options)
	options = options or {}
	local build = self:getBuild()
	local query = util.lower(util.trim(tostring(options.query or "")))
	local typeFilter = options.type and util.lower(tostring(options.type)) or nil
	local limit = util.clamp(tonumber(options.limit) or 20, 1, 100)
	local offset = math.max(0, tonumber(options.offset) or 0)
	local matches = {}
	for name, base in pairs(build.data.itemBases) do
		local include = true
		if query ~= "" then
			include = util.lower(name):find(query, 1, true) ~= nil
		end
		if include and typeFilter then
			include = util.lower(base.type or "") == typeFilter or util.lower(base.subType or "") == typeFilter
		end
		if include then
			matches[#matches + 1] = { name = name, base = base }
		end
	end
	table.sort(matches, function(a, b)
		return util.lower(a.name) < util.lower(b.name)
	end)
	local output = {}
	for index = offset + 1, math.min(#matches, offset + limit) do
		local entry = matches[index]
		output[#output + 1] = {
			name = entry.name,
			type = entry.base.type,
			sub_type = entry.base.subType,
			level = entry.base.req and entry.base.req.level,
			tags = entry.base.tags,
		}
	end
	return {
		total = #matches,
		offset = offset,
		limit = limit,
		bases = output,
	}
end

function Api:itemSummary(item)
	local output = {
		id = item.id,
		name = item.title or item.name,
		full_name = item.name,
		title = item.title,
		base = item.baseName,
		type = item.type,
		rarity = item.rarity,
		primary_slot = item:GetPrimarySlot(),
		quality = item.quality,
		variant = item.variant,
		socket_count = item.sockets and #item.sockets or 0,
		corrupted = item.corrupted == true,
		influences = (function()
			local influences = {}
			for _, info in ipairs(itemLib.influenceInfo.all) do
				if item[info.key] then
					influences[#influences + 1] = info.key
				end
			end
			return influences
		end)(),
		anoints = (function()
			local anoints = {}
			for _, line in ipairs(item.enchantModLines or {}) do
				local name = line.line and line.line:match("^Allocates (.+)$")
				if name then
					anoints[#anoints + 1] = name
				end
			end
			return anoints
		end)(),
	}
	return output
end

function Api:validateItemSlot(item, slot)
	local build = self:getBuild()
	local itemsTab = build.itemsTab
	itemsTab:UpdateSockets()
	local slotControl = itemsTab.slots[slot]
	if not slotControl then
		local available = {}
		for _, candidate in ipairs(itemsTab.orderedSlots) do
			if candidate:IsShown() then
				available[#available + 1] = candidate.slotName
			end
		end
		error("Unknown item slot '" .. tostring(slot) .. "'. Available slots: " .. table.concat(available, ", "), 0)
	end
	if not slotControl:IsShown() then
		error("Item slot '" .. tostring(slot) .. "' is not currently active", 0)
	end
	local nodeId = slot:match("^Jewel (%d+)$")
	if nodeId and not build.spec.allocNodes[tonumber(nodeId)] then
		error("Jewel socket " .. nodeId .. " is not allocated", 0)
	end
	if not itemsTab:IsItemValidForSlot(item, slot, itemsTab.activeItemSet) then
		error("Item '" .. tostring(item.name or item.baseName) .. "' cannot be equipped in slot '" .. tostring(slot) .. "'", 0)
	end
	return slotControl
end

function Api:equipItem(item, slot)
	local build = self:getBuild()
	local itemsTab = build.itemsTab
	if not slot or slot == "" then
		if item.type == "Jewel" then
			error("Jewel items require an explicit slot such as 'Jewel 12345'", 0)
		end
		slot = item:GetPrimarySlot()
	end
	local slotControl = self:validateItemSlot(item, slot)
	slotControl:SetSelItemId(item.id)
	itemsTab:PopulateSlots()
	return slot
end

function Api:checkItemConstraints(item, options)
	options = options or {}
	if (item.rarity == "UNIQUE" or item.rarity == "RELIC") and self.constraints.no_uniques then
		error("Unique items are disabled by the current no_uniques constraint", 0)
	end
	if self.constraints.level and not options.allow_requirement_violation then
		local level = item.requirements and item.requirements.level
		if level and level > self:getBuild().characterLevel then
			error(string.format("Item requires level %d but the character is level %d", level, self:getBuild().characterLevel), 0)
		end
	end
end

function Api:itemsAddRaw(options)
	options = options or {}
	local build = self:getBuild()
	local itemsTab = build.itemsTab
	local raw = options.raw
	if type(raw) ~= "string" or raw == "" then
		error("items_add_raw requires raw item text", 0)
	end
	itemsTab:CreateDisplayItemFromRaw(raw, false)
	local item = itemsTab.displayItem
	if not item or not item.base then
		error("Could not parse item text; check the base item name", 0)
	end
	self:checkItemConstraints(item, options)
	if options.slot and options.slot ~= "" then
		self:validateItemSlot(item, options.slot)
	end
	itemsTab:AddItem(item, true)
	itemsTab:SetDisplayItem()
	itemsTab:PopulateSlots()
	itemsTab:UpdateSockets()
	local equippedSlot
	if options.slot and options.slot ~= "" then
		equippedSlot = self:equipItem(item, options.slot)
	elseif options.equip ~= false and item.type ~= "Jewel" then
		for _, slot in ipairs(itemsTab.orderedSlots) do
			if not slot.nodeId and slot.selItemId == 0 and slot:IsShown() and itemsTab:IsItemValidForSlot(item, slot.slotName, itemsTab.activeItemSet) then
				slot:SetSelItemId(item.id)
				equippedSlot = slot.slotName
				break
			end
		end
		itemsTab:PopulateSlots()
	end
	self:frame()
	local summary = self:itemSummary(item)
	summary.equipped_in = equippedSlot
	return summary
end

function Api:itemsAddUnique(options)
	options = options or {}
	local dbItem = self:findUnique(options.name)
	if not dbItem then
		error("Unknown unique '" .. tostring(options.name) .. "'. Use items_search_uniques.", 0)
	end
	local lines = {}
	for line in dbItem:BuildRaw():gmatch("[^\n]+") do
		lines[#lines + 1] = line
	end
	local additions = {}
	local function removeLines(prefix)
		for index = #lines, 1, -1 do
			if lines[index]:match("^" .. prefix) then
				table.remove(lines, index)
			end
		end
	end
	if options.variant ~= nil then
		local variant = tonumber(options.variant)
		if not variant then
			error("variant must be a number", 0)
		end
		removeLines("Selected Variant:")
		additions[#additions + 1] = "Selected Variant: " .. tostring(variant)
	end
	if options.variant_groups then
		removeLines("Selected Variant Group:")
		for key, value in pairs(options.variant_groups) do
			local groupId = tonumber(key)
			local variantId = tonumber(value)
			if not groupId or not variantId then
				error("variant_groups must map numeric group ids to numeric variant ids", 0)
			end
			additions[#additions + 1] = "Selected Variant Group: " .. groupId .. "=" .. variantId
		end
	end
	if options.quality ~= nil then
		local quality = tonumber(options.quality)
		if not quality then
			error("quality must be a number", 0)
		end
		removeLines("Quality:")
		additions[#additions + 1] = "Quality: " .. tostring(quality)
	end
	if options.sockets and options.sockets ~= "" then
		removeLines("Sockets:")
		additions[#additions + 1] = "Sockets: " .. tostring(options.sockets)
	end
	local insertAt = #lines + 1
	for index, line in ipairs(lines) do
		if line:match("^LevelReq:") or line:match("^Implicits:") or line:match("^Item Level:") or line:match("^Radius:") or line:match("^Limited to:") or line:match("^Requires Class") then
			insertAt = index
			break
		end
	end
	for index = #additions, 1, -1 do
		table.insert(lines, insertAt, additions[index])
	end
	local raw = table.concat(lines, "\n")
	return self:itemsAddRaw({
		raw = raw,
		slot = options.slot,
		equip = options.equip,
		allow_requirement_violation = options.allow_requirement_violation,
	})
end

function Api:baseItemForSearch(options)
	local base = options.base
	if type(base) ~= "string" or base == "" then
		error("A base item name is required", 0)
	end
	local item = new("Item"):Item("Rarity: RARE\nSearch\n" .. base .. "\nImplicits: 0")
	if not item.base then
		error("Unknown base '" .. tostring(base) .. "'", 0)
	end
	item.itemLevel = tonumber(options.item_level)
	if options.influences then
		local valid = {}
		for _, info in ipairs(itemLib.influenceInfo.all) do
			valid[info.key] = true
		end
		local seen = {}
		local count = 0
		for _, key in ipairs(options.influences) do
			if not valid[key] then
				error("Unknown influence '" .. tostring(key) .. "'", 0)
			end
			if not seen[key] then
				seen[key] = true
				count = count + 1
				item[key] = true
			end
		end
		if count > 2 then
			error("An item may have at most two influences", 0)
		end
		if count > 0 and not item.canBeInfluenced then
			error("Item cannot be influenced", 0)
		end
	end
	return item
end

function Api:itemsSearchMods(options)
	options = options or {}
	local item = self:baseItemForSearch(options)
	local modType = options.type and util.lower(tostring(options.type)) or nil
	local query = util.lower(util.trim(tostring(options.query or "")))
	local limit = util.clamp(tonumber(options.limit) or 30, 1, 100)
	local offset = math.max(0, tonumber(options.offset) or 0)
	local matches = {}
	for modId, mod in pairs(item.affixes) do
		local include = not item:CheckIfModIsDelve(mod) and item:CanHaveMod(mod)
		if include and modType then
			include = util.lower(mod.type or "") == modType
		end
		if include and query ~= "" then
			local searchable = util.lower(table.concat({ modId, mod.affix or "", mod.type or "", table.concat(mod, "\n") }, "\n"))
			include = searchable:find(query, 1, true) ~= nil
		end
		if include then
			matches[#matches + 1] = { id = modId, mod = mod }
		end
	end
	table.sort(matches, function(a, b)
		local aOrder = a.mod.statOrder and a.mod.statOrder[1] or 0
		local bOrder = b.mod.statOrder and b.mod.statOrder[1] or 0
		if aOrder ~= bOrder then
			return aOrder < bOrder
		end
		if (a.mod.level or 0) ~= (b.mod.level or 0) then
			return (a.mod.level or 0) < (b.mod.level or 0)
		end
		return a.id < b.id
	end)
	local output = {}
	for index = offset + 1, math.min(#matches, offset + limit) do
		local entry = matches[index]
		local mod = entry.mod
		local lines = {}
		for _, line in ipairs(mod) do
			lines[#lines + 1] = line
		end
		output[#output + 1] = {
			mod_id = entry.id,
			type = mod.type,
			affix = mod.affix,
			group = mod.group,
			level = mod.level,
			weight = item:GetModSpawnWeight(mod),
			stat_order = mod.statOrder,
			lines = lines,
			available_at_item_level = not item.itemLevel or not mod.level or mod.level <= item.itemLevel,
		}
	end
	return {
		base = item.baseName,
		total = #matches,
		offset = offset,
		limit = limit,
		mods = output,
	}
end

function Api:findAffixMod(item, reference, affixType)
	local mod = item.affixes[reference]
	if mod then
		return reference, mod
	end
	local target = util.lower(util.trim(tostring(reference or "")))
	local foundId
	local found
	local foundCount = 0
	for modId, candidate in pairs(item.affixes) do
		if util.lower(candidate.affix or "") == target and (not affixType or candidate.type == affixType) then
			foundId = modId
			found = candidate
			foundCount = foundCount + 1
		end
	end
	if foundCount > 1 then
		error("Ambiguous affix '" .. tostring(reference) .. "'; use a mod_id", 0)
	end
	return foundId, found
end

function Api:validateRareOptions(options)
	options = options or {}
	local item = self:baseItemForSearch(options)
	local errors = {}
	local warnings = {}
	local selected = {}
	local selectedGroups = {}
	local perSideLimit = ((item.type == "Jewel" and not (item.base.subType == "Abyss" and item.corrupted)) or item.type == "Graft") and 2 or 3
	local function validateList(list, affixType)
		if #list > perSideLimit then
			errors[#errors + 1] = string.format("Too many %ss: %d (maximum %d)", affixType:lower(), #list, perSideLimit)
		end
		for _, affix in ipairs(list) do
			local reference = affix.mod_id or affix.line
			local modId, mod
			if reference then
				modId, mod = self:findAffixMod(item, reference, affixType)
			end
			if not mod then
				errors[#errors + 1] = "Unknown " .. affixType:lower() .. " '" .. tostring(reference) .. "'"
			else
				if mod.type ~= affixType then
					errors[#errors + 1] = string.format("Modifier '%s' is a %s, not a %s", reference, mod.type or "modifier", affixType)
				end
				if item:CheckIfModIsDelve(mod) then
					errors[#errors + 1] = string.format("Delve modifier '%s' is not part of normal rare crafting", reference)
				elseif not item:CanHaveMod(mod) then
					errors[#errors + 1] = string.format("Modifier '%s' cannot appear on %s", reference, item.baseName)
				end
				if mod.group and selectedGroups[mod.group] then
					errors[#errors + 1] = string.format("Modifier '%s' duplicates affix group '%s'", reference, mod.group)
				end
				if mod.group then
					selectedGroups[mod.group] = true
				end
				if item.itemLevel and mod.level and mod.level > item.itemLevel then
					warnings[#warnings + 1] = string.format("Modifier '%s' requires level %d but item level is %d", reference, mod.level, item.itemLevel)
				end
				selected[#selected + 1] = { modId = modId, mod = mod, range = affix.range }
			end
		end
	end
	validateList(options.prefixes or {}, "Prefix")
	validateList(options.suffixes or {}, "Suffix")
	return {
		item = item,
		valid = #errors == 0,
		errors = errors,
		warnings = warnings,
		affixes = selected,
	}
end

function Api:itemsValidateRare(options)
	local validation = self:validateRareOptions(options)
	return {
		valid = validation.valid,
		base = validation.item.baseName,
		item_level = validation.item.itemLevel,
		errors = validation.errors,
		warnings = validation.warnings,
		affix_count = #validation.affixes,
	}
end

function Api:itemsAddRare(options)
	options = options or {}
	local build = self:getBuild()
	local base = options.base
	if type(base) ~= "string" or base == "" then
		error("items_add_rare requires a base item name", 0)
	end
	if not build.data.itemBases[base] then
		local suggestions = {}
		local target = util.lower(base)
		for name in pairs(build.data.itemBases) do
			if util.lower(name):find(target, 1, true) then
				suggestions[#suggestions + 1] = name
				if #suggestions >= 8 then
					break
				end
			end
		end
		table.sort(suggestions)
		local message = "Unknown base '" .. tostring(base) .. "'"
		if #suggestions > 0 then
			message = message .. ". Suggestions: " .. table.concat(suggestions, ", ")
		end
		error(message .. ". Use items_search_bases.", 0)
	end
	local hasPrefixes = type(options.prefixes) == "table" and #options.prefixes > 0
	local hasSuffixes = type(options.suffixes) == "table" and #options.suffixes > 0
	local hasStructured = hasPrefixes or hasSuffixes
	local hasRawMods = (type(options.mods) == "string" and #options.mods > 0)
		or (type(options.mods) == "table" and #options.mods > 0)
	if hasStructured and hasRawMods then
		error("items_add_rare accepts either mods or prefixes/suffixes, not both", 0)
	end
	if hasStructured then
		local validation = self:validateRareOptions(options)
		if not validation.valid then
			error(table.concat(validation.errors, "; "), 0)
		end
		local lines = {
			"Rarity: RARE",
			tostring(options.name or "MCP Rare"),
			base,
		}
		for _, info in ipairs(itemLib.influenceInfo.all) do
			if validation.item[info.key] then
				lines[#lines + 1] = info.display .. " Item"
			end
		end
		if options.item_level then
			lines[#lines + 1] = "Item Level: " .. tostring(math.floor(tonumber(options.item_level) or 0))
		end
		if options.quality then
			lines[#lines + 1] = "Quality: " .. tostring(math.floor(tonumber(options.quality) or 0))
		end
		if options.sockets and options.sockets ~= "" then
			lines[#lines + 1] = "Sockets: " .. tostring(options.sockets)
		end
		lines[#lines + 1] = "Implicits: 0"
		local item = new("Item"):Item(table.concat(lines, "\n"))
		local perSideLimit = ((item.type == "Jewel" and not (item.base.subType == "Abyss" and item.corrupted)) or item.type == "Graft") and 2 or 3
		item.crafted = true
		item.affixLimit = perSideLimit * 2
		item.prefixes = { limit = perSideLimit }
		item.suffixes = { limit = perSideLimit }
		for index = 1, perSideLimit do
			item.prefixes[index] = { modId = "None" }
			item.suffixes[index] = { modId = "None" }
		end
		local prefixIndex = 0
		local suffixIndex = 0
		for _, entry in ipairs(validation.affixes) do
			if entry.mod.type == "Prefix" then
				prefixIndex = prefixIndex + 1
				item.prefixes[prefixIndex] = { modId = entry.modId, range = tonumber(entry.range) or 0.5 }
			else
				suffixIndex = suffixIndex + 1
				item.suffixes[suffixIndex] = { modId = entry.modId, range = tonumber(entry.range) or 0.5 }
			end
		end
		item:Craft()
		local summary = self:itemsAddRaw({
			raw = item:BuildRaw(),
			slot = options.slot,
			equip = options.equip,
			allow_requirement_violation = options.allow_requirement_violation,
		})
		summary.warnings = validation.warnings
		return summary
	end
	local mods = options.mods
	local modLines = {}
	if type(mods) == "string" then
		for line in mods:gmatch("[^\n]+") do
			modLines[#modLines + 1] = util.trim(line)
		end
	elseif type(mods) == "table" then
		for _, line in ipairs(mods) do
			modLines[#modLines + 1] = util.trim(tostring(line))
		end
	end
	local lines = {
		"Rarity: RARE",
		tostring(options.name or "MCP Rare"),
		base,
	}
	if options.influences then
		local validated = self:baseItemForSearch({ base = base, influences = options.influences })
		for _, info in ipairs(itemLib.influenceInfo.all) do
			if validated[info.key] then
				lines[#lines + 1] = info.display .. " Item"
			end
		end
	end
	if options.item_level then
		lines[#lines + 1] = "Item Level: " .. tostring(math.floor(tonumber(options.item_level) or 0))
	end
	if options.quality then
		lines[#lines + 1] = "Quality: " .. tostring(math.floor(tonumber(options.quality) or 0))
	end
	if options.sockets and options.sockets ~= "" then
		lines[#lines + 1] = "Sockets: " .. tostring(options.sockets)
	end
	lines[#lines + 1] = "Implicits: 0"
	for _, line in ipairs(modLines) do
		if line ~= "" then
			lines[#lines + 1] = line
		end
	end
	return self:itemsAddRaw({
		raw = table.concat(lines, "\n"),
		slot = options.slot,
		equip = options.equip,
		allow_requirement_violation = options.allow_requirement_violation,
	})
end

function Api:itemsGet(options)
	options = options or {}
	local build = self:getBuild()
	local itemsTab = build.itemsTab
	itemsTab:UpdateSockets()
	itemsTab:PopulateSlots()
	local equipped = {}
	for _, slot in ipairs(itemsTab.orderedSlots) do
		local item = itemsTab.items[slot.selItemId]
		if item and slot:IsShown() then
			equipped[#equipped + 1] = {
				slot = slot.slotName,
				label = slot.label,
				item_id = item.id,
				name = item.name or item.baseName,
			}
		end
	end
	local items = {}
	for _, itemId in ipairs(itemsTab.itemOrderList) do
		local item = itemsTab.items[itemId]
		if item then
			local entry = self:itemSummary(item)
			if options.include_raw then
				entry.raw = item:BuildRaw()
			end
			items[#items + 1] = entry
		end
	end
	local slots = {}
	for _, slot in ipairs(itemsTab.orderedSlots) do
		if slot:IsShown() then
			slots[#slots + 1] = {
				name = slot.slotName,
				label = slot.label,
				item_id = slot.selItemId ~= 0 and slot.selItemId or nil,
				active = slot.active == true,
			}
		end
	end
	return {
		items = items,
		equipped = equipped,
		slots = slots,
	}
end

function Api:getItem(itemId)
	local id = tonumber(itemId)
	local item = id and self:getBuild().itemsTab.items[id]
	if not item then
		error("Unknown item id '" .. tostring(itemId) .. "'", 0)
	end
	return item
end

function Api:replaceItem(item)
	local build = self:getBuild()
	local itemsTab = build.itemsTab
	itemsTab:AddItem(item, true)
	itemsTab:PopulateSlots()
	itemsTab:UpdateSockets()
	itemsTab:AddUndoState()
	build.buildFlag = true
	self:frame()
	return self:itemSummary(item)
end

function Api:itemsSetSockets(options)
	options = options or {}
	local item = self:getItem(options.item_id)
	if not item.base or not item.base.socketLimit then
		error("Item does not support sockets", 0)
	end
	local sockets = parseSocketString(options.sockets)
	local normalSockets = 0
	local abyssalSockets = 0
	for _, socket in ipairs(sockets) do
		if socket.color == "A" then
			abyssalSockets = abyssalSockets + 1
		else
			normalSockets = normalSockets + 1
		end
	end
	local requiredAbyssal = math.max(abyssalSockets, item.abyssalSocketCount or 0)
	local normalCapacity = math.max(0, item.base.socketLimit - requiredAbyssal)
	if normalSockets > normalCapacity then
		error(string.format("Item allows at most %d normal sockets with %d abyssal sockets", normalCapacity, requiredAbyssal), 0)
	end
	local clone = new("Item"):Item(item:BuildRaw())
	clone.id = item.id
	clone.sockets = sockets
	clone:BuildAndParseRaw()
	return self:replaceItem(clone)
end

function Api:itemsOptimiseSockets(options)
	options = options or {}
	local build = self:getBuild()
	local item = self:getItem(options.item_id)
	if not item.base or not item.base.socketLimit then
		error("Item does not support sockets", 0)
	end
	local slotName = options.slot
	if not slotName then
		for _, slot in ipairs(build.itemsTab.orderedSlots) do
			if slot.selItemId == item.id then
				slotName = slot.slotName
				break
			end
		end
	end
	if not slotName then
		error("Item is not equipped; pass slot to optimise sockets", 0)
	end
	if not groupSlots[slotName] then
		error("Unknown skill group slot '" .. tostring(slotName) .. "'", 0)
	end
	local oldInfo = socketInfo(item)
	local maxSockets = (item.base and item.base.socketLimit or 0) - oldInfo.abyssal
	if maxSockets < 0 then
		maxSockets = 0
	end
	local sockets = {}
	local groupId = 0
	local colours = { "R", "G", "B" }
	for _, group in ipairs(build.skillsTab.socketGroupList) do
		if group.slot == slotName then
			for _, gem in ipairs(group.gemList or {}) do
				local granted = gem.grantedEffect or (gem.gemData and gem.gemData.grantedEffect)
				if granted and maxSockets > 0 then
					local color = granted.color and colours[granted.color] or "W"
					sockets[#sockets + 1] = { color = color, group = groupId }
					maxSockets = maxSockets - 1
				end
			end
			groupId = groupId + 1
		end
	end
	for _ = 1, oldInfo.abyssal do
		groupId = groupId + 1
		sockets[#sockets + 1] = { color = "A", group = groupId }
	end
	local clone = new("Item"):Item(item:BuildRaw())
	clone.id = item.id
	clone.sockets = sockets
	clone:BuildAndParseRaw()
	local summary = self:replaceItem(clone)
	return {
		item = summary,
		sockets = socketString(clone),
		socket_diagnostics = socketInfo(clone),
	}
end

function Api:itemsEquip(options)
	options = options or {}
	local build = self:getBuild()
	local itemId = tonumber(options.item_id)
	local item = itemId and build.itemsTab.items[itemId]
	if not item then
		error("Unknown item id '" .. tostring(options.item_id) .. "'", 0)
	end
	local slot = self:equipItem(item, options.slot)
	self:frame()
	local summary = self:itemSummary(item)
	summary.equipped_in = slot
	return summary
end

function Api:maxEnchantSlots(item)
	if item.canHaveFourEnchants then
		return 4
	elseif item.canHaveThreeEnchants then
		return 3
	elseif item.canHaveTwoEnchants then
		return 2
	end
	return 1
end

function Api:resolveNotable(reference)
	local build = self:getBuild()
	local node
	if type(reference) == "number" or (type(reference) == "string" and tonumber(reference)) then
		node = build.spec.tree.nodes[tonumber(reference)]
	else
		local name = util.lower(util.trim(tostring(reference or "")))
		node = build.spec.tree.notableMap[name] or build.spec.tree.ascendancyMap[name]
	end
	if not node then
		error("Unknown notable '" .. tostring(reference) .. "'", 0)
	end
	if not node.recipe then
		error("Passive '" .. tostring(node.dn or node.name) .. "' cannot be anointed", 0)
	end
	return node
end

function Api:isAnointableItem(item)
	return item and item.base and not item.base.cannotBeAnointed
		and item.base.subType ~= "Talisman"
		and (item.canBeAnointed or item.base.type == "Amulet")
end

function Api:itemsAnoint(options)
	options = options or {}
	local item = self:getItem(options.item_id)
	if not self:isAnointableItem(item) then
		error("Item is not anointable", 0)
	end
	local clone = new("Item"):Item(item:BuildRaw())
	clone.id = item.id
	local function removeAnointLines(lines)
		for index = #lines, 1, -1 do
			if lines[index].line and lines[index].line:match("^Allocates ") then
				table.remove(lines, index)
			end
		end
	end
	removeAnointLines(clone.enchantModLines)
	removeAnointLines(clone.implicitModLines)
	if not options.remove then
		local node = self:resolveNotable(options.notable or options.node_id or options.node_name)
		local slot = util.clamp(math.floor(tonumber(options.slot) or 1), 1, self:maxEnchantSlots(clone))
		local position = math.min(slot, #clone.enchantModLines + 1)
		table.insert(clone.enchantModLines, position, { crafted = true, line = "Allocates " .. node.dn })
	end
	clone:BuildAndParseRaw()
	local summary = self:replaceItem(clone)
	summary.anoints = self:itemSummary(clone).anoints
	return summary
end

function Api:itemsSetEnchant(options)
	options = options or {}
	local item = self:getItem(options.item_id)
	local clone = new("Item"):Item(item:BuildRaw())
	clone.id = item.id
	local slot = util.clamp(math.floor(tonumber(options.slot) or 1), 1, self:maxEnchantSlots(clone))
	if options.remove == true then
		if clone.enchantModLines[slot] then
			table.remove(clone.enchantModLines, slot)
		end
	else
		local line = options.line
		if type(line) ~= "string" or line == "" then
			error("items_set_enchant requires line or remove=true", 0)
		end
		if clone.enchantModLines[slot] then
			table.remove(clone.enchantModLines, slot)
		end
		local position = math.min(slot, #clone.enchantModLines + 1)
		table.insert(clone.enchantModLines, position, { crafted = true, line = line })
	end
	clone:BuildAndParseRaw()
	return self:replaceItem(clone)
end

function Api:itemsSetInfluences(options)
	options = options or {}
	local item = self:getItem(options.item_id)
	if not item.canBeInfluenced then
		error("Item cannot be influenced", 0)
	end
	local requested = options.influences
	if type(requested) ~= "table" then
		error("items_set_influences requires influences; pass an empty array to clear", 0)
	end
	local valid = {}
	for _, info in ipairs(itemLib.influenceInfo.all) do
		valid[info.key] = true
	end
	local seen = {}
	local keys = {}
	for _, key in ipairs(requested) do
		if not valid[key] then
			error("Unknown influence '" .. tostring(key) .. "'", 0)
		end
		if not seen[key] then
			seen[key] = true
			keys[#keys + 1] = key
		end
	end
	if #keys > 2 then
		error("An item may have at most two influences", 0)
	end
	local clone = new("Item"):Item(item:BuildRaw())
	clone.id = item.id
	clone:ResetInfluence()
	for _, key in ipairs(keys) do
		clone[key] = true
	end
	clone:BuildAndParseRaw()
	local summary = self:replaceItem(clone)
	summary.influences = self:itemSummary(clone).influences
	return summary
end

function Api:itemsCorrupt(options)
	options = options or {}
	local item = self:getItem(options.item_id)
	if item.corrupted then
		error("Item is already corrupted", 0)
	end
	if item.corruptible == false then
		error("Item cannot be corrupted", 0)
	end
	local clone = new("Item"):Item(item:BuildRaw())
	clone.id = item.id
	clone.corrupted = true
	if options.implicits ~= nil then
		if type(options.implicits) ~= "table" then
			error("implicits must be an array", 0)
		end
		local maxImplicits = clone.corruptImplicitCount or 2
		if #options.implicits > maxImplicits then
			error(string.format("Item allows at most %d corruption implicits", maxImplicits), 0)
		end
		clone.implicitModLines = {}
		for _, line in ipairs(options.implicits) do
			clone.implicitModLines[#clone.implicitModLines + 1] = { line = tostring(line) }
		end
	end
	clone:BuildAndParseRaw()
	return self:replaceItem(clone)
end

function Api:itemsUpdateRaw(options)
	options = options or {}
	local item = self:getItem(options.item_id)
	if type(options.raw) ~= "string" or options.raw == "" then
		error("items_update_raw requires raw item text", 0)
	end
	local clone = new("Item"):Item(options.raw)
	if not clone.base then
		error("Could not parse item text", 0)
	end
	clone.id = item.id
	self:checkItemConstraints(clone, options)
	return self:replaceItem(clone)
end

function Api:itemsSetFlaskActive(options)
	options = options or {}
	local item = self:getItem(options.item_id)
	if item.type ~= "Flask" and item.type ~= "Tincture" then
		error("Item is not a flask or tincture", 0)
	end
	local build = self:getBuild()
	local itemsTab = build.itemsTab
	local slotName
	for _, slot in ipairs(itemsTab.orderedSlots) do
		if slot.selItemId == item.id then
			slotName = slot.slotName
			break
		end
	end
	if not slotName then
		error("Flask is not equipped", 0)
	end
	local active = options.active
	if active == nil then
		active = not itemsTab.slots[slotName].active
	else
		active = active == true
	end
	local slot = itemsTab.slots[slotName]
	slot.active = active
	itemsTab.activeItemSet[slotName].active = active
	if slot.controls and slot.controls.activate then
		slot.controls.activate.state = active
	end
	itemsTab:AddUndoState()
	build.buildFlag = true
	self:frame()
	return {
		item_id = item.id,
		slot = slotName,
		active = active,
	}
end

function Api:itemsRemove(options)
	options = options or {}
	local build = self:getBuild()
	local itemId = tonumber(options.item_id)
	local item = itemId and build.itemsTab.items[itemId]
	if not item then
		error("Unknown item id '" .. tostring(options.item_id) .. "'", 0)
	end
	build.itemsTab:DeleteItem(item)
	self:frame()
	return {
		removed_item_id = itemId,
		items = self:itemsGet({}).items,
	}
end

function Api:configVars()
	return require("Modules.ConfigOptions")
end

function Api:configEntries()
	local build = self:getBuild()
	local entries = {}
	local section
	for _, varData in ipairs(self:configVars()) do
		if varData.section then
			section = varData.section
		elseif varData.var then
			local options
			if varData.type == "list" then
				options = {}
				for _, option in ipairs(varData.list or {}) do
					options[#options + 1] = {
						value = option.val,
						label = util.stripColors(option.label or tostring(option.val)),
					}
				end
			end
			entries[#entries + 1] = {
				var = varData.var,
				label = util.stripColors(varData.label or varData.var),
				type = varData.type,
				section = section,
				options = options,
				default = build.configTab:GetDefaultState(varData.var, type(build.configTab.input[varData.var])),
				tooltip = type(varData.tooltip) == "string" and util.stripColors(varData.tooltip) or nil,
				current = build.configTab.input[varData.var],
			}
		end
	end
	return entries
end

function Api:configSearch(options)
	options = options or {}
	local query = util.lower(util.trim(tostring(options.query or "")))
	local sectionFilter = options.section and util.lower(tostring(options.section)) or nil
	local limit = util.clamp(tonumber(options.limit) or 20, 1, 100)
	local offset = math.max(0, tonumber(options.offset) or 0)
	local matches = {}
	for _, entry in ipairs(self:configEntries()) do
		local include = true
		if sectionFilter then
			include = entry.section and util.lower(entry.section) == sectionFilter
		end
		if include and query ~= "" then
			local searchable = util.lower(table.concat({ entry.var, entry.label or "", entry.section or "", entry.tooltip or "" }, "\n"))
			include = searchable:find(query, 1, true) ~= nil
		end
		if include then
			matches[#matches + 1] = entry
		end
	end
	table.sort(matches, function(a, b)
		return a.var < b.var
	end)
	local output = {}
	for index = offset + 1, math.min(#matches, offset + limit) do
		output[#output + 1] = matches[index]
	end
	return {
		total = #matches,
		offset = offset,
		limit = limit,
		options = output,
	}
end

function Api:configGet()
	local build = self:getBuild()
	local output = {}
	for _, entry in ipairs(self:configEntries()) do
		local current = build.configTab.input[entry.var]
		if current ~= nil and current ~= entry.default then
			output[entry.var] = util.sanitize(current)
		end
	end
	local customMods
	local configSet = build.configTab.configSets[build.configTab.activeConfigSetId]
	for _, block in ipairs(configSet.customModsList or {}) do
		if block.title == "MCP" then
			customMods = block.text
			break
		end
	end
	if customMods == nil then
		customMods = build.configTab.input.customMods
	end
	if customMods and customMods ~= "" then
		output.customMods = customMods
	end
	return {
		set = objectMap(output),
	}
end

function Api:configSet(options)
	options = options or {}
	local build = self:getBuild()
	local values = options.values or {}
	local vars = {}
	for _, entry in ipairs(self:configEntries()) do
		vars[entry.var] = entry
	end
	local changed = {}
	local coerced = {}
	for key, value in pairs(values) do
		local entry = vars[key]
		if not entry then
			error("Unknown config option '" .. tostring(key) .. "'. Use config_search.", 0)
		end
		if entry.type == "check" then
			if type(value) ~= "boolean" then
				error("Config option '" .. key .. "' expects a boolean", 0)
			end
		elseif entry.type == "count" or entry.type == "integer" or entry.type == "countAllowZero" or entry.type == "float" then
			value = tonumber(value)
			if not value then
				error("Config option '" .. key .. "' expects a number", 0)
			end
		elseif entry.type == "list" then
			local matched
			for _, option in ipairs(entry.options or {}) do
				if option.value == value or tostring(option.value) == tostring(value) then
					matched = option.value
					break
				end
			end
			if matched == nil then
				local names = {}
				for _, option in ipairs(entry.options or {}) do
					names[#names + 1] = tostring(option.value)
				end
				error("Config option '" .. key .. "' must be one of: " .. table.concat(names, ", "), 0)
			end
			value = matched
		else
			if type(value) ~= "string" then
				error("Config option '" .. key .. "' expects a string", 0)
			end
		end
		coerced[key] = value
	end
	for key, value in pairs(coerced) do
		build.configTab.input[key] = value
		changed[key] = value
	end
	if options.custom_mods ~= nil then
		local configSet = build.configTab.configSets[build.configTab.activeConfigSetId]
		configSet.customModsList = configSet.customModsList or {}
		local block
		for _, candidate in ipairs(configSet.customModsList) do
			if candidate.title == "MCP" then
				block = candidate
				break
			end
		end
		if not block then
			block = { title = "MCP", enabled = true, text = "" }
			table.insert(configSet.customModsList, block)
		end
		block.text = tostring(options.custom_mods)
		build.configTab.input.customMods = block.text
		changed.customMods = block.text
	end
	build.configTab:UpdateControls()
	build.configTab:BuildModList()
	self:frame()
	return {
		changed = objectMap(util.sanitize(changed)),
		config = self:configGet(),
		summary = self:summary(),
	}
end

function Api:whatIfItem(options)
	if options.item_id then
		local itemId = tonumber(options.item_id)
		local item = itemId and self:getBuild().itemsTab.items[itemId]
		if not item then
			error("Unknown item id '" .. tostring(options.item_id) .. "'", 0)
		end
		return item
	end
	local raw = options.item_raw
	if not raw and options.unique_name then
		local unique = self:findUnique(options.unique_name)
		if not unique then
			error("Unknown unique '" .. tostring(options.unique_name) .. "'", 0)
		end
		raw = unique:BuildRaw()
	end
	if not raw then
		return nil
	end
	local item = new("Item"):Item(raw)
	if not item.base then
		error("Could not parse the comparison item", 0)
	end
	item:BuildModList()
	return item
end

function Api:calcWhatIf(options)
	options = options or {}
	local build = self:getBuild()
	local calcFunc, calcBase = build.calcsTab:GetMiscCalculator()
	if not calcFunc or not calcBase then
		error("Calculations are not ready", 0)
	end
	local override = {}
	local changes = {}
	if options.add_node_ids then
		local nodes = {}
		for _, idValue in ipairs(options.add_node_ids) do
			local node = build.spec.nodes[tonumber(idValue)]
			if not node then
				error("Unknown node id '" .. tostring(idValue) .. "'", 0)
			end
			if not node.alloc then
				if node.type == "Mastery" then
					error("Mastery what-if comparisons are not supported; allocate the mastery with passives_allocate instead", 0)
				end
				if not node.path then
					error("Node '" .. tostring(node.dn or node.name) .. "' is unreachable", 0)
				end
				for _, pathNode in ipairs(node.path) do
					nodes[pathNode] = true
				end
			end
		end
		override.addNodes = nodes
		changes.add_node_ids = options.add_node_ids
	end
	if options.remove_node_ids then
		local nodes = {}
		for _, idValue in ipairs(options.remove_node_ids) do
			local node = build.spec.nodes[tonumber(idValue)]
			if not node then
				error("Unknown node id '" .. tostring(idValue) .. "'", 0)
			end
			if node.alloc then
				for _, depNode in ipairs(node.depends or {}) do
					nodes[depNode] = true
				end
			end
		end
		override.removeNodes = nodes
		changes.remove_node_ids = options.remove_node_ids
	end
	local item = self:whatIfItem(options)
	if item then
		local slot = options.slot
		if not slot then
			local itemsTab = build.itemsTab
			for _, candidate in ipairs(itemsTab.orderedSlots) do
				if candidate.selItemId == item.id then
					slot = candidate.slotName
					break
				end
			end
		end
		if not slot then
			if item.type == "Jewel" then
				error("Jewel comparisons require an explicit slot", 0)
			end
			slot = item:GetPrimarySlot()
		end
		self:validateItemSlot(item, slot)
		override.repSlotName = slot
		override.repItem = item
		changes.item = self:itemSummary(item)
		changes.slot = slot
	end
	if options.toggle_flask_id then
		local itemId = tonumber(options.toggle_flask_id)
		local flask = itemId and build.itemsTab.items[itemId]
		if not flask then
			error("Unknown flask item id '" .. tostring(options.toggle_flask_id) .. "'", 0)
		end
		override.toggleFlask = flask
		changes.toggle_flask_id = itemId
	end
	if options.conditions then
		override.conditions = options.conditions
		changes.conditions = options.conditions
	end
	if not next(override) then
		error("calc_what_if requires at least one change", 0)
	end
	local output = calcFunc(override, options.use_full_dps)
	local result = {
		base = objectMap(self:curatedStats(calcBase)),
		result = objectMap(self:curatedStats(output)),
		delta = objectMap({}),
		changes = changes,
	}
	local requested = options.stats or curatedStatKeys
	result.base_requested = objectMap({})
	result.result_requested = objectMap({})
	for _, requestedKey in ipairs(requested) do
		local key = self:resolveStatName(requestedKey)
		local baseValue = calcBase[key]
		local resultValue = output[key]
		if type(baseValue) == "number" or type(resultValue) == "number" then
			result.base_requested[key] = util.sanitize(baseValue)
			result.result_requested[key] = util.sanitize(resultValue)
		end
	end
	local deltaKeys = {}
	for key in pairs(result.result) do
		deltaKeys[key] = true
	end
	for _, requestedKey in ipairs(requested) do
		deltaKeys[self:resolveStatName(requestedKey)] = true
	end
	for key in pairs(deltaKeys) do
		local baseValue = calcBase[key]
		local resultValue = output[key]
		if type(baseValue) == "number" and type(resultValue) == "number" then
			local delta = resultValue - baseValue
			result.delta[key] = {
				value = util.sanitize(delta),
				percent = baseValue ~= 0 and util.sanitize(delta / math.abs(baseValue) * 100) or nil,
			}
		end
	end
	return result
end

function Api:itemsCompare(options)
	options = options or {}
	local result = self:calcWhatIf({
		item_raw = options.item_raw,
		unique_name = options.unique_name,
		item_id = options.item_id,
		slot = options.slot,
		stats = options.stats,
		use_full_dps = options.use_full_dps,
	})
	if result.changes and result.changes.item then
		local item = self:whatIfItem(options)
		local requirements = item.requirements or {}
		local level = requirements.level
		local buildOutput = self:getBuild().calcsTab.mainOutput or {}
		local problems = {}
		if level and level > self:getBuild().characterLevel then
			problems[#problems + 1] = string.format("requires level %d but the character is level %d", level, self:getBuild().characterLevel)
		end
		if requirements.strMod and requirements.strMod > (buildOutput.Str or 0) then
			problems[#problems + 1] = string.format("requires %d Strength but the build has %d", requirements.strMod, buildOutput.Str or 0)
		end
		if requirements.dexMod and requirements.dexMod > (buildOutput.Dex or 0) then
			problems[#problems + 1] = string.format("requires %d Dexterity but the build has %d", requirements.dexMod, buildOutput.Dex or 0)
		end
		if requirements.intMod and requirements.intMod > (buildOutput.Int or 0) then
			problems[#problems + 1] = string.format("requires %d Intelligence but the build has %d", requirements.intMod, buildOutput.Int or 0)
		end
		if #problems > 0 then
			result.requirement_warning = "Item " .. table.concat(problems, "; ")
		end
	end
	return result
end


function Api:statAliasMap()
	local build = self:getBuild()
	local aliases = {}
	local function add(entry, minion)
		if not entry or not entry.stat or entry.childStat then
			return
		end
		local stat = entry.stat
		local labels = { entry.label, stat, tostring(stat):gsub("(%l)(%u)", "%1 %2") }
		for _, label in ipairs(labels) do
			local key = normaliseStatText(label)
			if key ~= "" then
				local existing = aliases[key]
				if not existing or existing == stat then
					aliases[key] = stat
				else
					aliases[key] = false
				end
			end
		end
	end
	for _, entry in ipairs(build.displayStats or {}) do
		add(entry, false)
	end
	for _, entry in ipairs(build.minionDisplayStats or {}) do
		add(entry, true)
	end
	return aliases
end

function Api:resolveStatName(name)
	local build = self:getBuild()
	local output = build.calcsTab.mainOutput or {}
	if output[name] ~= nil then
		return name
	end
	for key in pairs(output) do
		if type(key) == "string" and util.lower(key) == util.lower(name) then
			return key
		end
	end
	local alias = self:statAliasMap()[normaliseStatText(name)]
	if alias and output[alias] ~= nil then
		return alias
	end
	return name
end

function Api:statsSearch(options)
	options = options or {}
	local build = self:getBuild()
	local output = build.calcsTab.mainOutput or {}
	local query = util.lower(util.trim(tostring(options.query or "")))
	local tokens = {}
	for token in query:gmatch("%S+") do
		tokens[#tokens + 1] = token
	end
	local curated = {}
	for _, key in ipairs(curatedStatKeys) do
		curated[key] = true
	end
	local labels = {}
	for _, entry in ipairs(build.displayStats or {}) do
		if entry.stat and entry.label and not entry.childStat then
			labels[entry.stat] = labels[entry.stat] or {}
			labels[entry.stat][#labels[entry.stat] + 1] = entry.label
		end
	end
	local matches = {}
	for key, value in pairs(output) do
		if type(key) == "string" and (type(value) == "number" or type(value) == "boolean") then
			local parts = { key }
			for _, label in ipairs(labels[key] or {}) do
				parts[#parts + 1] = label
			end
			local haystack = util.lower(table.concat(parts, " "))
			local score = 0
			local matched = true
			for _, token in ipairs(tokens) do
				local ok, tokenScore = fuzzyStatMatch(haystack, token)
				if not ok then
					matched = false
					break
				end
				score = score + tokenScore
			end
			if matched then
				if query ~= "" and haystack:find(query, 1, true) then
					score = score + 500
				end
				if curated[key] then
					score = score + 100
				end
				matches[#matches + 1] = { key = key, labels = labels[key] or {}, score = score, value = value }
			end
		end
	end
	table.sort(matches, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		return a.key < b.key
	end)
	local limit = util.clamp(tonumber(options.limit) or 30, 1, 100)
	local offset = math.max(0, tonumber(options.offset) or 0)
	local stats = {}
	for index = offset + 1, math.min(#matches, offset + limit) do
		local entry = matches[index]
		stats[#stats + 1] = {
			key = entry.key,
			label = entry.labels[1],
			labels = entry.labels,
			curated = curated[entry.key] or false,
			value = util.sanitize(entry.value),
		}
	end
	return {
		total = #matches,
		offset = offset,
		limit = limit,
		stats = stats,
	}
end

function Api:calcStats(options)
	options = options or {}
	local build = self:getBuild()
	local output = build.calcsTab.mainOutput or {}
	local result = {
		main_skill = self:mainSkillInfo(build),
		stats = objectMap(self:curatedStats(output)),
	}
	if options.stats then
		result.requested = objectMap({})
		result.aliases = objectMap({})
		result.missing = {}
		for _, requestedKey in ipairs(options.stats) do
			local key = self:resolveStatName(requestedKey)
			local value = output[key]
			if value ~= nil then
				result.requested[key] = util.sanitize(value)
				if key ~= requestedKey then
					result.aliases[requestedKey] = key
				end
			else
				result.missing[#result.missing + 1] = requestedKey
			end
		end
	end
	if options.all then
		result.all = objectMap(util.sanitize(output, { depth = 4, maxKeys = 800, maxArray = 2000 }))
	end
	if options.include_minion then
		local minion = build.calcsTab.mainEnv and build.calcsTab.mainEnv.minion
		if minion then
			result.minion = {
				name = minion.minionData and minion.minionData.name,
				stats = objectMap(self:curatedStats(minion.output or {})),
				all = options.all and objectMap(util.sanitize(minion.output or {}, { depth = 4, maxKeys = 800, maxArray = 2000 })) or nil,
			}
		end
	end
	result.warnings = self:warnings(build)
	return result
end

function Api:calcBreakdown(options)
	options = options or {}
	local build = self:getBuild()
	local requestedStat = options.stat
	if type(requestedStat) ~= "string" or requestedStat == "" then
		error("calc_breakdown requires a stat name", 0)
	end
	local stat = self:resolveStatName(requestedStat)
	local actorName = options.actor == "minion" and "minion" or "player"
	local environment = build.calcsTab.mainEnv
	local actor = environment and environment[actorName]
	if not actor then
		error("No " .. actorName .. " calculation environment is available", 0)
	end
	local breakdown = actor.breakdown and actor.breakdown[stat]
	local value = actor.output and actor.output[stat]
	if breakdown == nil and value == nil then
		error("Unknown stat '" .. stat .. "'", 0)
	end
	return {
		stat = stat,
		requested_stat = requestedStat,
		actor = actorName,
		value = util.sanitize(value),
		breakdown = util.sanitize(breakdown, { depth = 6, strip = true }),
	}
end

function Api:calcWarnings()
	local build = self:getBuild()
	return {
		warnings = self:warnings(build),
		main_skill = self:mainSkillInfo(build),
	}
end

return M
