local S = require("mcp.schema")

local defs = {
	{
		name = "passives_search",
		description = "Search passive tree nodes by name, stat text, type, or ascendancy. Returns node ids and path cost from the allocated tree.",
		inputSchema = S.object({
			query = S.string("Text to match in node name or stats"),
			type = S.enum({ "all", "notable", "keystone", "mastery", "socket", "normal", "ascendancy" }, "Node type filter"),
			ascendancy = S.string("Ascendancy name filter"),
			allocated = S.boolean("Filter to allocated or unallocated nodes"),
			reachable = S.boolean("Only return nodes reachable from the allocated tree"),
			limit = S.integer("Maximum results", { minimum = 1, maximum = 100 }),
			offset = S.integer("Result offset", { minimum = 0 }),
		}),
		annotations = { readOnlyHint = true },
	},
	{
		name = "passives_get",
		description = "Return allocated passive nodes, mastery selections, and point usage.",
		inputSchema = S.object(),
		annotations = { readOnlyHint = true },
	},
	{
		name = "passives_allocate",
		description = "Allocate passive nodes by id or name. Path nodes are allocated automatically. Mastery nodes require a mastery_effects entry.",
		inputSchema = S.object({
			ids = S.array(S.integer("Node id"), "Node ids to allocate"),
			names = S.array(S.string("Node name"), "Node names to allocate"),
			mastery_effects = S.anyObject("Map of mastery node id to mastery effect id"),
		}),
		annotations = { destructiveHint = true },
	},
	{
		name = "passives_deallocate",
		description = "Deallocate passive nodes by id or name, including dependent nodes.",
		inputSchema = S.object({
			ids = S.array(S.integer("Node id"), "Node ids to deallocate"),
			names = S.array(S.string("Node name"), "Node names to deallocate"),
		}),
		annotations = { destructiveHint = true },
	},
	{
		name = "passives_set_mastery",
		description = "Select the effect for an allocated or unallocated mastery node.",
		inputSchema = S.object({
			node_id = S.integer("Mastery node id"),
			effect_id = S.integer("Mastery effect id"),
		}, { "node_id", "effect_id" }),
		annotations = { destructiveHint = true },
	},
}

local handlers = {}

function handlers.passives_search(args, ctx)
	return ctx.api():passivesSearch(args)
end

function handlers.passives_get(_, ctx)
	return ctx.api():passivesGet()
end

function handlers.passives_allocate(args, ctx)
	return ctx.api():passivesAllocate(args)
end

function handlers.passives_deallocate(args, ctx)
	return ctx.api():passivesDeallocate(args)
end

function handlers.passives_set_mastery(args, ctx)
	return ctx.api():passivesSetMastery(args)
end

return { defs = defs, handlers = handlers }
