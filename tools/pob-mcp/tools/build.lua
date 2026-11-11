local S = require("mcp.schema")

local defs = {
	{
		name = "meta_info",
		description = "Return PoB version, current tree version, classes, ascendancies, and game-data counts.",
		inputSchema = S.object(),
		annotations = { readOnlyHint = true },
	},
	{
		name = "build_new",
		description = "Create a fresh build. Optionally set class, ascendancy, and level.",
		inputSchema = S.object({
			name = S.string("Build name"),
			class = S.string("Class name or class id"),
			ascendancy = S.string("Ascendancy name or id"),
			level = S.integer("Character level", { minimum = 1, maximum = 100 }),
		}),
		annotations = { destructiveHint = true },
	},
	{
		name = "build_import",
		description = "Load a build from XML, a PoB share code, or a file path.",
		inputSchema = S.object({
			xml = S.string("Raw PathOfBuilding XML"),
			code = S.string("PoB share code"),
			path = S.string("Path to a build XML file"),
			name = S.string("Build name"),
			convert = S.boolean("Convert legacy build versions to the current version"),
		}),
		annotations = { destructiveHint = true },
	},
	{
		name = "build_export",
		description = "Export the active build as XML or a PoB share code. Optionally write it to a file.",
		inputSchema = S.object({
			format = S.enum({ "xml", "code" }, "Export format, defaults to xml"),
			path = S.string("Optional file path to write"),
		}),
		annotations = { readOnlyHint = true },
	},
	{
		name = "build_state",
		description = "Return the active build summary: class, ascendancy, level, points, main skill, stats, and warnings.",
		inputSchema = S.object(),
		annotations = { readOnlyHint = true },
	},
	{
		name = "build_snapshot",
		description = "Save the active build XML under a snapshot name.",
		inputSchema = S.object({
			name = S.string("Snapshot name; generated when omitted"),
		}),
		annotations = { destructiveHint = false },
	},
	{
		name = "build_restore",
		description = "Restore a build snapshot saved with build_snapshot.",
		inputSchema = S.object({
			name = S.string("Snapshot name"),
		}, { "name" }),
		annotations = { destructiveHint = true },
	},
	{
		name = "character_set",
		description = "Change level, class, or ascendancy of the active build.",
		inputSchema = S.object({
			level = S.integer("Character level", { minimum = 1, maximum = 100 }),
			class = S.string("Class name or class id"),
			ascendancy = S.string("Ascendancy name or id"),
		}),
		annotations = { destructiveHint = true },
	},
}

local handlers = {}

function handlers.meta_info(_, ctx)
	return ctx.api():metaInfo()
end

function handlers.build_new(args, ctx)
	return ctx.api():newBuild(args)
end

function handlers.build_import(args, ctx)
	return ctx.api():importBuild(args)
end

function handlers.build_export(args, ctx)
	return ctx.api():exportBuild(args)
end

function handlers.build_state(_, ctx)
	return ctx.api():summary()
end

function handlers.build_snapshot(args, ctx)
	return ctx.api():snapshot(args)
end

function handlers.build_restore(args, ctx)
	return ctx.api():restore(args)
end

function handlers.character_set(args, ctx)
	return ctx.api():characterSet(args)
end

return { defs = defs, handlers = handlers }
