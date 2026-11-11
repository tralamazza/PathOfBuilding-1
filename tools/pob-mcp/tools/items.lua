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
		name = "items_add_raw",
		description = "Add an item from PoB item text. Optionally equip it in a slot; otherwise the first valid empty slot is used.",
		inputSchema = S.object({
			raw = S.string("Full PoB item text"),
			slot = S.string("Slot name, such as Helmet, Ring 1, Weapon 1, or Jewel 12345"),
			equip = S.boolean("Auto-equip when slot is omitted; defaults to true"),
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
		}, { "name" }),
		annotations = { destructiveHint = true },
	},
	{
		name = "items_add_rare",
		description = "Add a rare item from a base and modifier lines.",
		inputSchema = S.object({
			base = S.string("Base item name"),
			name = S.string("Rare item name"),
			mods = S.array(S.string("Modifier line"), "Explicit modifier lines"),
			item_level = S.integer("Item level", { minimum = 1, maximum = 100 }),
			quality = S.integer("Item quality", { minimum = 0, maximum = 100 }),
			sockets = S.string("Socket string"),
			slot = S.string("Slot name"),
			equip = S.boolean("Auto-equip when slot is omitted; defaults to true"),
		}, { "base" }),
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

function handlers.items_add_raw(args, ctx)
	return ctx.api():itemsAddRaw(args)
end

function handlers.items_add_unique(args, ctx)
	return ctx.api():itemsAddUnique(args)
end

function handlers.items_add_rare(args, ctx)
	return ctx.api():itemsAddRare(args)
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
