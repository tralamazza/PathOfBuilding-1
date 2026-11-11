local S = require("mcp.schema")

local defs = {
	{
		name = "config_search",
		description = "Search configuration options such as buffs, conditions, enemy settings, and custom modifiers.",
		inputSchema = S.object({
			query = S.string("Text to match in option name, label, section, or tooltip"),
			section = S.string("Section name filter"),
			limit = S.integer("Maximum results", { minimum = 1, maximum = 100 }),
			offset = S.integer("Result offset", { minimum = 0 }),
		}),
		annotations = { readOnlyHint = true },
	},
	{
		name = "config_get",
		description = "Return configuration values that differ from their defaults, including custom modifiers.",
		inputSchema = S.object(),
		annotations = { readOnlyHint = true },
	},
	{
		name = "config_set",
		description = "Set configuration options and/or custom modifier lines. Use config_search to discover valid keys.",
		inputSchema = S.object({
			values = S.anyObject("Map of config variable names to values"),
			custom_mods = S.string("Custom modifier lines separated by newlines"),
		}),
		annotations = { destructiveHint = true },
	},
}

local handlers = {}

function handlers.config_search(args, ctx)
	return ctx.api():configSearch(args)
end

function handlers.config_get(_, ctx)
	return ctx.api():configGet()
end

function handlers.config_set(args, ctx)
	return ctx.api():configSet(args)
end

return { defs = defs, handlers = handlers }
