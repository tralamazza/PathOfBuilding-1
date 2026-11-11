local S = require("mcp.schema")

local defs = {
	{
		name = "skills_search",
		description = "Search gems by name, tags, or active/support kind.",
		inputSchema = S.object({
			query = S.string("Text to match in gem name or tags"),
			kind = S.enum({ "active", "support" }, "Gem kind"),
			tags = S.array(S.string("Tag"), "Required gem tags"),
			limit = S.integer("Maximum results", { minimum = 1, maximum = 100 }),
			offset = S.integer("Result offset", { minimum = 0 }),
		}),
		annotations = { readOnlyHint = true },
	},
	{
		name = "skills_get",
		description = "Return all skill groups, gems, and the main group.",
		inputSchema = S.object(),
		annotations = { readOnlyHint = true },
	},
	{
		name = "skills_add_group",
		description = "Add a skill group. Provide gems in socket order; the first non-support gem is usually the main skill.",
		inputSchema = S.object({
			gems = S.array(S.object({
				name = S.string("Gem name"),
				level = S.integer("Gem level", { minimum = 1, maximum = 40 }),
				quality = S.integer("Gem quality", { minimum = 0, maximum = 100 }),
				enabled = S.boolean("Whether the gem is enabled"),
				count = S.integer("Gem count", { minimum = 1 }),
			}, { "name" }), "Gems in socket order"),
			slot = S.string("Item slot label, such as Helmet or Weapon 1"),
			label = S.string("Skill group label"),
			enabled = S.boolean("Whether the group is enabled"),
			set_main = S.boolean("Set this group as the main skill group"),
		}, { "gems" }),
		annotations = { destructiveHint = true },
	},
	{
		name = "skills_remove_group",
		description = "Remove a skill group by index.",
		inputSchema = S.object({
			group = S.integer("Skill group index", { minimum = 1 }),
		}, { "group" }),
		annotations = { destructiveHint = true },
	},
	{
		name = "skills_set_main",
		description = "Set the main skill group and optionally the active skill part.",
		inputSchema = S.object({
			group = S.integer("Skill group index", { minimum = 1 }),
			active = S.integer("Active skill index inside the group", { minimum = 1 }),
		}, { "group" }),
		annotations = { destructiveHint = true },
	},
}

local handlers = {}

function handlers.skills_search(args, ctx)
	return ctx.api():skillsSearch(args)
end

function handlers.skills_get(_, ctx)
	return ctx.api():skillsGet()
end

function handlers.skills_add_group(args, ctx)
	return ctx.api():skillsAddGroup(args)
end

function handlers.skills_remove_group(args, ctx)
	return ctx.api():skillsRemoveGroup(args)
end

function handlers.skills_set_main(args, ctx)
	return ctx.api():skillsSetMain(args)
end

return { defs = defs, handlers = handlers }
