local S = require("mcp.schema")

local defs = {
	{
		name = "calc_stats",
		description = "Return calculated stats for the active build. Use all=true for the raw output table.",
		inputSchema = S.object({
			stats = S.array(S.string("Output stat name"), "Specific output stat names to return"),
			all = S.boolean("Include all scalar and nested output values"),
			include_minion = S.boolean("Include minion output"),
		}),
		annotations = { readOnlyHint = true },
	},
	{
		name = "stats_search",
		description = "Search calculated output stat keys by name, display label, or fuzzy text.",
		inputSchema = S.object({
			query = S.string("Text to match in stat key or display label"),
			limit = S.integer("Maximum results", { minimum = 1, maximum = 100 }),
			offset = S.integer("Result offset", { minimum = 0 }),
		}),
		annotations = { readOnlyHint = true },
	},
	{
		name = "calc_what_if",
		description = "Evaluate passive-node, item, flask, or condition changes without mutating the active build.",
		inputSchema = S.object({
			add_node_ids = S.array(S.integer("Node id"), "Node ids to add"),
			remove_node_ids = S.array(S.integer("Node id"), "Node ids to remove"),
			item_raw = S.string("Raw PoB item text to compare"),
			unique_name = S.string("Unique item name to compare"),
			item_id = S.integer("Existing item id to compare"),
			slot = S.string("Slot to replace"),
			toggle_flask_id = S.integer("Flask item id to toggle"),
			conditions = S.array(S.string("Condition flag"), "Extra condition flags"),
			stats = S.array(S.string("Output stat name"), "Stats to compare"),
			use_full_dps = S.boolean("Use Full DPS for the comparison"),
		}),
		annotations = { readOnlyHint = true },
	},
	{
		name = "calc_breakdown",
		description = "Return the calculation breakdown for a stat, such as Life, Mana, TotalDPS, or Armour.",
		inputSchema = S.object({
			stat = S.string("Output stat name"),
			actor = S.enum({ "player", "minion" }, "Actor to inspect, defaults to player"),
		}, { "stat" }),
		annotations = { readOnlyHint = true },
	},
	{
		name = "calc_warnings",
		description = "Return build warnings and main-skill messages.",
		inputSchema = S.object(),
		annotations = { readOnlyHint = true },
	},
}

local handlers = {}

function handlers.calc_stats(args, ctx)
	return ctx.api():calcStats(args)
end

function handlers.stats_search(args, ctx)
	return ctx.api():statsSearch(args)
end

function handlers.calc_what_if(args, ctx)
	return ctx.api():calcWhatIf(args)
end

function handlers.calc_breakdown(args, ctx)
	return ctx.api():calcBreakdown(args)
end

function handlers.calc_warnings(_, ctx)
	return ctx.api():calcWarnings()
end

return { defs = defs, handlers = handlers }
