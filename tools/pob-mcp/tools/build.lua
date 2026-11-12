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
		annotations = { readOnlyHint = false, destructiveHint = true },
	},
	{
		name = "build_state",
		description = "Return the active build summary: class, ascendancy, level, points, main skill, stats, and warnings.",
		inputSchema = S.object(),
		annotations = { readOnlyHint = true },
	},
	{
		name = "build_list",
		description = "List PoB build files in the build directory, optionally filtered and scoped to a subdirectory.",
		inputSchema = S.object({
			query = S.string("Text to match in build name, class, or ascendancy"),
			sub_path = S.string("Subdirectory relative to the build root"),
		}),
		annotations = { readOnlyHint = true },
	},
	{
		name = "build_load",
		description = "Load a PoB build file from the build directory.",
		inputSchema = S.object({
			name = S.string("Build name without .xml"),
			path = S.string("Path relative to the build directory"),
			sub_path = S.string("Subdirectory relative to the build root"),
			convert = S.boolean("Convert legacy build versions"),
		}),
		annotations = { destructiveHint = true },
	},
	{
		name = "build_rename",
		description = "Rename a PoB build file in the build directory.",
		inputSchema = S.object({
			name = S.string("Source build name without .xml"),
			path = S.string("Source path relative to the build directory"),
			new_name = S.string("New build name without .xml"),
			sub_path = S.string("Destination subdirectory"),
			overwrite = S.boolean("Overwrite an existing destination"),
		}, { "new_name" }),
		annotations = { destructiveHint = true },
	},
	{
		name = "build_fork",
		description = "Fork the active build or a build file into a new build file.",
		inputSchema = S.object({
			name = S.string("Source build name without .xml"),
			path = S.string("Source path relative to the build directory"),
			new_name = S.string("New build name without .xml"),
			sub_path = S.string("Destination subdirectory"),
			overwrite = S.boolean("Overwrite an existing destination"),
			switch = S.boolean("Load the fork after writing, defaults to true"),
		}, { "new_name" }),
		annotations = { destructiveHint = true },
	},
	{
		name = "build_delete",
		description = "Delete a PoB build file. The active build cannot be deleted.",
		inputSchema = S.object({
			name = S.string("Build name without .xml"),
			path = S.string("Path relative to the build directory"),
			sub_path = S.string("Subdirectory relative to the build root"),
		}),
		annotations = { destructiveHint = true },
	},
	{
		name = "build_snapshot",
		description = "Save the active build XML under a snapshot name, optionally to persistent storage.",
		inputSchema = S.object({
			name = S.string("Snapshot name; generated when omitted"),
			persistent = S.boolean("Write the snapshot under the PoB user data directory"),
		}),
		annotations = { destructiveHint = false },
	},
	{
		name = "build_restore",
		description = "Restore a snapshot saved with build_snapshot.",
		inputSchema = S.object({
			name = S.string("Snapshot name"),
			persistent = S.boolean("Read from persistent storage when not in memory"),
		}, { "name" }),
		annotations = { destructiveHint = true },
	},
	{
		name = "build_snapshot_list",
		description = "List in-memory and persistent build snapshots.",
		inputSchema = S.object(),
		annotations = { readOnlyHint = true },
	},
	{
		name = "build_snapshot_delete",
		description = "Delete a snapshot from memory and persistent storage.",
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
	{
		name = "build_set_constraints",
		description = "Set build constraints such as level, point budget, and whether unique items are allowed.",
		inputSchema = S.object({
			level = S.integer("Character level", { minimum = 1, maximum = 100 }),
			max_points = S.integer("Maximum passive points", { minimum = 0 }),
			no_uniques = S.boolean("Reject unique items"),
			enforce_points = S.boolean("Reject passive allocations over the point budget"),
		}),
		annotations = { destructiveHint = true },
	},
	{
		name = "build_validate",
		description = "Validate point budget, item requirements, skill links, resistances, sustain, and configured constraints.",
		inputSchema = S.object(),
		annotations = { readOnlyHint = true },
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

function handlers.build_list(args, ctx)
	return ctx.api():buildList(args)
end

function handlers.build_load(args, ctx)
	return ctx.api():buildLoad(args)
end

function handlers.build_rename(args, ctx)
	return ctx.api():buildRename(args)
end

function handlers.build_fork(args, ctx)
	return ctx.api():buildFork(args)
end

function handlers.build_delete(args, ctx)
	return ctx.api():buildDelete(args)
end

function handlers.build_snapshot(args, ctx)
	return ctx.api():snapshot(args)
end

function handlers.build_snapshot_list(_, ctx)
	return ctx.api():snapshotList()
end

function handlers.build_snapshot_delete(args, ctx)
	return ctx.api():snapshotDelete(args)
end

function handlers.build_restore(args, ctx)
	return ctx.api():restore(args)
end

function handlers.character_set(args, ctx)
	return ctx.api():characterSet(args)
end

function handlers.build_set_constraints(args, ctx)
	return ctx.api():setConstraints(args)
end

function handlers.build_validate(_, ctx)
	return ctx.api():validateBuild()
end

return { defs = defs, handlers = handlers }
