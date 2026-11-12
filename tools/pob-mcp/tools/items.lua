local S = require("mcp.schema")

local defs = {
	{
		name = "items_search_uniques",
		description = "Search the unique item database. Use the returned name with items_add_unique.",
		inputSchema = S.object({
			query = S.string("Text to match in unique name, base, or modifiers"),
			slot = S.string("Primary slot filter, such as Helmet or Ring"),
			base = S.string("Base item name filter"),
			include_raw = S.boolean("Include full PoB item text in results"),
			limit = S.integer("Maximum results", { minimum = 1, maximum = 100 }),
			offset = S.integer("Result offset", { minimum = 0 }),
		}),
		annotations = { readOnlyHint = true },
	},
	{
		name = "items_search_bases",
		description = "Search item base types for rare item creation.",
		inputSchema = S.object({
			query = S.string("Text to match in base name"),
			type = S.string("Item type or subtype filter"),
			limit = S.integer("Maximum results", { minimum = 1, maximum = 100 }),
			offset = S.integer("Result offset", { minimum = 0 }),
		}),
		annotations = { readOnlyHint = true },
	},
	{
		name = "items_search_templates",
		description = "Search the bundled rare item template database.",
		inputSchema = S.object({
			query = S.string("Text to match in template name, base, or modifiers"),
			slot = S.string("Primary slot filter"),
			base = S.string("Base item name filter"),
			include_raw = S.boolean("Include full PoB item text"),
			limit = S.integer("Maximum results", { minimum = 1, maximum = 100 }),
			offset = S.integer("Result offset", { minimum = 0 }),
		}),
		annotations = { readOnlyHint = true },
	},
	{
		name = "items_add_template",
		description = "Add a rare item from the bundled template database.",
		inputSchema = S.object({
			name = S.string("Template name or title"),
			slot = S.string("Slot name"),
			equip = S.boolean("Auto-equip when slot is omitted; defaults to true"),
			allow_requirement_violation = S.boolean("Allow items above the character level requirement"),
		}, { "name" }),
		annotations = { destructiveHint = true },
	},
	{
		name = "items_add_raw",
		description = "Add an item from PoB item text. Optionally equip it in a slot; otherwise the first valid empty slot is used.",
		inputSchema = S.object({
			raw = S.string("Full PoB item text"),
			slot = S.string("Slot name, such as Helmet, Ring 1, Weapon 1, or Jewel 12345"),
			equip = S.boolean("Auto-equip when slot is omitted; defaults to true"),
			allow_requirement_violation = S.boolean("Allow items above the character level requirement"),
		}, { "raw" }),
		annotations = { destructiveHint = true },
	},
	{
		name = "items_add_unique",
		description = "Add a unique item by name, with optional variant, quality, and sockets.",
		inputSchema = S.object({
			name = S.string("Unique name"),
			variant = S.integer("Variant id from items_search_uniques"),
			variant_groups = S.anyObject("Map of variant group id to variant id"),
			quality = S.integer("Item quality", { minimum = 0, maximum = 100 }),
			sockets = S.string("Socket string, such as B-B-B-B-B-B or G-G-R"),
			slot = S.string("Slot name"),
			equip = S.boolean("Auto-equip when slot is omitted; defaults to true"),
			allow_requirement_violation = S.boolean("Allow items above the character level requirement"),
		}, { "name" }),
		annotations = { destructiveHint = true },
	},
	{
		name = "items_search_mods",
		description = "Search the normal rare-crafting affix pool for a base, mirroring the PoB crafting UI.",
		inputSchema = S.object({
			base = S.string("Base item name"),
			item_level = S.integer("Item level", { minimum = 1, maximum = 100 }),
			type = S.enum({ "Prefix", "Suffix" }, "Affix type"),
			query = S.string("Text to match in affix name or lines"),
			influences = S.array(S.string("Influence key"), "Influence context, up to two"),
			limit = S.integer("Maximum results", { minimum = 1, maximum = 100 }),
			offset = S.integer("Result offset", { minimum = 0 }),
		}, { "base" }),
		annotations = { readOnlyHint = true },
	},
	{
		name = "items_validate_rare",
		description = "Validate structured prefix/suffix modifiers against the PoB crafting affix pool.",
		inputSchema = S.object({
			base = S.string("Base item name"),
			item_level = S.integer("Item level", { minimum = 1, maximum = 100 }),
			influences = S.array(S.string("Influence key"), "Influence context, up to two"),
			prefixes = S.array(S.object({
				mod_id = S.string("Modifier id"),
				range = S.number("Roll range", { minimum = 0, maximum = 1 }),
			}), "Prefix modifiers"),
			suffixes = S.array(S.object({
				mod_id = S.string("Modifier id"),
				range = S.number("Roll range", { minimum = 0, maximum = 1 }),
			}), "Suffix modifiers"),
		}, { "base" }),
		annotations = { readOnlyHint = true },
	},
	{
		name = "items_add_rare",
		description = "Add a rare item from explicit modifier lines or structured prefixes/suffixes.",
		inputSchema = S.object({
			base = S.string("Base item name"),
			name = S.string("Rare item name"),
			mods = S.array(S.string("Modifier line"), "Explicit modifier lines"),
			prefixes = S.array(S.object({
				mod_id = S.string("Modifier id"),
				range = S.number("Roll range", { minimum = 0, maximum = 1 }),
			}), "Prefix modifiers"),
			suffixes = S.array(S.object({
				mod_id = S.string("Modifier id"),
				range = S.number("Roll range", { minimum = 0, maximum = 1 }),
			}), "Suffix modifiers"),
			influences = S.array(S.string("Influence key"), "Influence context, up to two"),
			item_level = S.integer("Item level", { minimum = 1, maximum = 100 }),
			quality = S.integer("Item quality", { minimum = 0, maximum = 100 }),
			sockets = S.string("Socket string"),
			slot = S.string("Slot name"),
			equip = S.boolean("Auto-equip when slot is omitted; defaults to true"),
			allow_requirement_violation = S.boolean("Allow items above the character level requirement"),
		}, { "base" }),
		annotations = { destructiveHint = true },
	},
	{
		name = "items_set_flask_active",
		description = "Set or toggle an equipped flask's active state.",
		inputSchema = S.object({
			item_id = S.integer("Item id"),
			active = S.boolean("Explicit active state; omit to toggle"),
		}, { "item_id" }),
		annotations = { destructiveHint = true },
	},
	{
		name = "items_anoint",
		description = "Add or remove an anoint on an item.",
		inputSchema = S.object({
			item_id = S.integer("Item id"),
			notable = S.string("Notable name"),
			node_id = S.integer("Notable node id"),
			slot = S.integer("Enchant slot", { minimum = 1, maximum = 4 }),
			remove = S.boolean("Remove the anoint instead of adding one"),
		}, { "item_id" }),
		annotations = { destructiveHint = true },
	},
	{
		name = "items_set_enchant",
		description = "Set or remove an item enchantment line.",
		inputSchema = S.object({
			item_id = S.integer("Item id"),
			slot = S.integer("Enchant slot", { minimum = 1, maximum = 4 }),
			line = S.string("Enchantment line"),
			remove = S.boolean("Remove the enchantment instead of adding one"),
		}, { "item_id" }),
		annotations = { destructiveHint = true },
	},
	{
		name = "items_set_influences",
		description = "Set up to two influences on an item, or clear them with an empty array.",
		inputSchema = S.object({
			item_id = S.integer("Item id"),
			influences = S.array(S.string("Influence key"), "Influence keys such as shaper, elder, crusader, cleansing, tangle"),
		}, { "item_id", "influences" }),
		annotations = { destructiveHint = true },
	},
	{
		name = "items_corrupt",
		description = "Corrupt an item, optionally replacing its corruption implicits.",
		inputSchema = S.object({
			item_id = S.integer("Item id"),
			implicits = S.array(S.string("Implicit line"), "Corruption implicit lines"),
		}, { "item_id" }),
		annotations = { destructiveHint = true },
	},
	{
		name = "items_update_raw",
		description = "Replace an existing item from full PoB item text.",
		inputSchema = S.object({
			item_id = S.integer("Item id"),
			raw = S.string("Full PoB item text"),
			allow_requirement_violation = S.boolean("Allow items above the character level requirement"),
		}, { "item_id", "raw" }),
		annotations = { destructiveHint = true },
	},
	{
		name = "items_compare",
		description = "Compare a candidate item against the currently equipped item without mutating the build.",
		inputSchema = S.object({
			item_raw = S.string("Raw PoB item text to compare"),
			unique_name = S.string("Unique item name to compare"),
			item_id = S.integer("Existing item id to compare"),
			slot = S.string("Slot to compare against"),
			stats = S.array(S.string("Output stat name"), "Stats to compare"),
			use_full_dps = S.boolean("Use Full DPS for the comparison"),
		}),
		annotations = { readOnlyHint = true },
	},
	{
		name = "items_set_sockets",
		description = "Set an item's socket layout using a string such as R-R-G B-B.",
		inputSchema = S.object({
			item_id = S.integer("Item id"),
			sockets = S.string("Socket layout, for example R-R-G B-B"),
		}, { "item_id", "sockets" }),
		annotations = { destructiveHint = true },
	},
	{
		name = "items_optimise_sockets",
		description = "Rebuild an item's sockets to match the gems assigned to one of its slots.",
		inputSchema = S.object({
			item_id = S.integer("Item id"),
			slot = S.string("Optional slot name; defaults to the item's primary slot"),
		}, { "item_id" }),
		annotations = { destructiveHint = true },
	},
	{
		name = "items_get",
		description = "Return all items and the currently equipped slot map.",
		inputSchema = S.object({
			include_raw = S.boolean("Include PoB item text for each item"),
		}),
		annotations = { readOnlyHint = true },
	},
	{
		name = "items_equip",
		description = "Equip an existing item in a specific slot.",
		inputSchema = S.object({
			item_id = S.integer("Item id"),
			slot = S.string("Slot name, such as Helmet, Ring 2, Weapon 1, or Jewel 12345"),
		}, { "item_id", "slot" }),
		annotations = { destructiveHint = true },
	},
	{
		name = "items_remove",
		description = "Remove an item from the build.",
		inputSchema = S.object({
			item_id = S.integer("Item id"),
		}, { "item_id" }),
		annotations = { destructiveHint = true },
	},
}

local handlers = {}

function handlers.items_search_uniques(args, ctx)
	return ctx.api():itemsSearchUniques(args)
end

function handlers.items_search_bases(args, ctx)
	return ctx.api():itemsSearchBases(args)
end

function handlers.items_search_templates(args, ctx)
	return ctx.api():itemsSearchTemplates(args)
end

function handlers.items_add_template(args, ctx)
	return ctx.api():itemsAddTemplate(args)
end

function handlers.items_add_raw(args, ctx)
	return ctx.api():itemsAddRaw(args)
end

function handlers.items_add_unique(args, ctx)
	return ctx.api():itemsAddUnique(args)
end

function handlers.items_search_mods(args, ctx)
	return ctx.api():itemsSearchMods(args)
end

function handlers.items_validate_rare(args, ctx)
	return ctx.api():itemsValidateRare(args)
end

function handlers.items_add_rare(args, ctx)
	return ctx.api():itemsAddRare(args)
end

function handlers.items_set_flask_active(args, ctx)
	return ctx.api():itemsSetFlaskActive(args)
end

function handlers.items_anoint(args, ctx)
	return ctx.api():itemsAnoint(args)
end

function handlers.items_set_enchant(args, ctx)
	return ctx.api():itemsSetEnchant(args)
end

function handlers.items_set_influences(args, ctx)
	return ctx.api():itemsSetInfluences(args)
end

function handlers.items_corrupt(args, ctx)
	return ctx.api():itemsCorrupt(args)
end

function handlers.items_update_raw(args, ctx)
	return ctx.api():itemsUpdateRaw(args)
end

function handlers.items_compare(args, ctx)
	return ctx.api():itemsCompare(args)
end

function handlers.items_set_sockets(args, ctx)
	return ctx.api():itemsSetSockets(args)
end

function handlers.items_optimise_sockets(args, ctx)
	return ctx.api():itemsOptimiseSockets(args)
end

function handlers.items_get(args, ctx)
	return ctx.api():itemsGet(args)
end

function handlers.items_equip(args, ctx)
	return ctx.api():itemsEquip(args)
end

function handlers.items_remove(args, ctx)
	return ctx.api():itemsRemove(args)
end

return { defs = defs, handlers = handlers }
