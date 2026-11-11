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

local function maxLinkedSockets(item)
	local counts = {}
	local maximum = 0
	for _, socket in ipairs(item and item.sockets or {}) do
		counts[socket.group] = (counts[socket.group] or 0) + 1
		if counts[socket.group] > maximum then
			maximum = counts[socket.group]
		end
	end
	return maximum
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
						addError("socket_link", label .. " needs " .. #(group.gemList or {}) .. " linked sockets but " .. group.slot .. " has " .. linked)
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
	return {
		name = name,
		bytes = #xml,
	}
end

function Api:restore(options)
	options = options or {}
	local name = options.name
	if not name or not self.snapshots[name] then
		error("Unknown snapshot '" .. tostring(name) .. "'", 0)
	end
	local savedConstraints = self.snapshotConstraints[name] or self:getConstraints()
	local ok, result = pcall(self.importBuild, self, { xml = self.snapshots[name], name = "Snapshot " .. name, convert = false })
	self.constraints = savedConstraints
	if not ok then
		error(result, 0)
	end
	return result
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

function Api:skillsGet()
	local build = self:getBuild()
	local output = {}
	for index, group in ipairs(build.skillsTab.socketGroupList) do
		local gems = {}
		for _, gem in ipairs(group.gemList or {}) do
			gems[#gems + 1] = {
				name = gem.nameSpec or (gem.gemData and gem.gemData.name),
				level = gem.level,
				quality = gem.quality,
				enabled = gem.enabled ~= false,
				count = gem.count or 1,
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
			gems = gems,
		}
	end
	return {
		main_group = build.mainSocketGroup or 1,
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
		gemList = {},
		mainActiveSkill = 1,
	}
	for _, gemInput in ipairs(gems) do
		local name = gemInput.name
		if type(name) ~= "string" or name == "" then
			error("Every gem needs a name", 0)
		end
		local gemData, err = self:findGem(name)
		if not gemData then
			error(err, 0)
		end
		local level = util.clamp(math.floor(tonumber(gemInput.level) or 20), 1, 40)
		local quality = util.clamp(math.floor(tonumber(gemInput.quality) or 0), 0, 100)
		local count = math.max(1, math.floor(tonumber(gemInput.count) or 1))
		group.gemList[#group.gemList + 1] = {
			nameSpec = gemData.name,
			gemId = gemData.id,
			skillId = gemData.grantedEffectId,
			level = level,
			quality = quality,
			enabled = gemInput.enabled ~= false,
			count = count,
			enableGlobal1 = true,
			enableGlobal2 = true,
		}
		if not (gemData.tags and gemData.tags.support == true) then
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
			}
		end
	end
	return {
		items = items,
		equipped = equipped,
		slots = slots,
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
	for _, key in ipairs(requested) do
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
	for _, key in ipairs(requested) do
		deltaKeys[key] = true
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
		result.missing = {}
		for _, key in ipairs(options.stats) do
			local value = output[key]
			if value ~= nil then
				result.requested[key] = util.sanitize(value)
			else
				result.missing[#result.missing + 1] = key
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
	local stat = options.stat
	if type(stat) ~= "string" or stat == "" then
		error("calc_breakdown requires a stat name", 0)
	end
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
