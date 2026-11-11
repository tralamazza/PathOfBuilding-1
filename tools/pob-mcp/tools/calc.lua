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

function handlers.calc_breakdown(args, ctx)
	return ctx.api():calcBreakdown(args)
end

function handlers.calc_warnings(_, ctx)
	return ctx.api():calcWarnings()
end

return { defs = defs, handlers = handlers }
