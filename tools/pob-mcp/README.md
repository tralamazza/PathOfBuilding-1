# PoB MCP Server

A pure-Lua MCP server for the Path of Building calculation engine. It runs PoB headlessly, keeps one active build in memory, and exposes tools for creating and editing builds and reading calculated stats.

No Python, Node, Docker, or GUI is required. The only runtime dependency is LuaJIT.

## Requirements

- LuaJIT 2.1 or newer (`brew install luajit` on macOS, or the equivalent package on Linux).
- A Path of Building checkout containing `src/` and `runtime/`.

The server includes small compatibility shims for the two things the headless engine needs:

- A pure-Lua fallback for `lua-utf8`. A real `luautf8` module is preferred when installed.
- A loader that strips the leading `#@` directive from `Launch.lua`, which newer LuaJIT versions reject.
- LuaJIT FFI access to system zlib for PoB share codes. XML import/export works even if zlib is unavailable.

## Running

```sh
/path/to/PathOfBuilding/tools/pob-mcp/pob-mcp
```

The server speaks MCP over stdio.

Example MCP client configuration:

```json
{
  "mcpServers": {
    "pob": {
      "command": "/path/to/PathOfBuilding/tools/pob-mcp/pob-mcp"
    }
  }
}
```

Environment variables:

| Variable | Purpose |
|---|---|
| `POB_PATH` | Path to the Path of Building repository. Detected from the launcher when omitted. |
| `POB_MCP_USER_PATH` | PoB user-data path. Defaults to `~/.pob-mcp`. |
| `POB_MCP_LUAJIT` | LuaJIT executable used by tests. |

The engine boots lazily on the first tool call. Startup is roughly 1.5 seconds and about 250 MB of memory on macOS. The process then stays warm.

## Tools

### Build lifecycle

| Tool | Purpose |
|---|---|
| `meta_info` | PoB version, tree version, classes, ascendancies, data counts. |
| `build_new` | Create a fresh build with optional class, ascendancy, and level. |
| `build_import` | Load XML, a PoB share code, or a file path. |
| `build_export` | Export XML or a share code, optionally to a file. |
| `build_state` | Compact build summary, stats, points, and warnings. |
| `build_snapshot` | Save the current build XML under a name. |
| `build_restore` | Restore a saved snapshot. |
| `character_set` | Change level, class, or ascendancy. |
| `build_set_constraints` | Set level, point budget, unique-item policy, and point enforcement. |
| `build_validate` | Validate point budget, item requirements, sockets, resistances, and sustain. |

### Passives

| Tool | Purpose |
|---|---|
| `passives_search` | Search by name, stat text, type, ascendancy, reachability, allocation. |
| `passives_plan` | Preview path cost and point-budget usage before allocating. |
| `passives_get` | Allocated nodes, mastery selections, and point usage. |
| `passives_allocate` | Allocate nodes by id or name; path nodes are added automatically. |
| `passives_deallocate` | Deallocate nodes and dependants. |
| `passives_set_mastery` | Select or change a mastery effect. |

Node ids are specific to the current tree version. Search results include `path_cost`, which is the number of unallocated nodes needed to connect the node to the current tree.

### Skills

| Tool | Purpose |
|---|---|
| `skills_search` | Search active gems and supports by name and tags. |
| `skills_get` | List skill groups, gems, and the main group. |
| `skills_add_group` | Add a socket group with level and quality per gem. |
| `skills_remove_group` | Remove a group by index. |
| `skills_set_main` | Select the main group and active skill part. |

### Items

| Tool | Purpose |
|---|---|
| `items_search_uniques` | Search the unique database by name, base, slot, or modifier text. |
| `items_compare` | Compare a candidate item against the equipped item without mutating the build. |
| `items_search_bases` | Search base item types for rare item creation. |
| `items_add_raw` | Add an item from full PoB item text. |
| `items_add_unique` | Add a unique by name, with optional variant and sockets. |
| `items_add_rare` | Add a rare from a base and explicit modifier lines. |
| `items_get` | List items and equipped slots. |
| `items_equip` | Equip an item in a specific slot, including `Jewel <nodeId>`. |
| `items_remove` | Remove an item. |

### Configuration and calculations

| Tool | Purpose |
|---|---|
| `config_search` | Search buffs, conditions, enemy settings, and custom modifiers. |
| `config_get` | Values that differ from their defaults, including custom modifiers. |
| `config_set` | Set config values and/or custom modifier text. |
| `calc_stats` | Calculated stats; `all=true` returns the raw output table. |
| `calc_what_if` | Evaluate node, item, flask, or condition changes without mutating the build. |
| `calc_breakdown` | Detailed calculation breakdown for a stat. |
| `calc_warnings` | Build warnings and main-skill messages. |

## Agent workflow

1. `meta_info` to discover classes and ascendancies.
2. `build_new` with class, ascendancy, and level; then `build_set_constraints` for level/budget/no-unique rules.
3. `skills_search` and `skills_add_group` for the main skill and supports.
4. `passives_search` and `passives_allocate` for the tree.
5. `items_search_uniques`, `items_add_unique`, or `items_add_rare`.
6. `config_search` and `config_set` for buffs, conditions, and custom modifiers.
7. `calc_stats`, `calc_breakdown`, and `calc_warnings` to inspect the result.
8. `build_validate`, then `build_export` for XML or a share code.

Use `build_snapshot` before trying alternatives and `build_restore` to return.

## Security and trust

This is a local stdio tool intended for a trusted MCP client. It can read and write files when an import or export path is supplied, so do not expose it to untrusted callers. It does not execute arbitrary Lua from builds, but if path access needs to be constrained, run it in a container or add an allowlist in front of the import/export handlers.

## Notes

- One MCP server process owns one active build. Use snapshots for alternatives.
- `build_set_constraints` enforces point budgets and can reject unique items. `build_validate` is the final check before exporting a build.
- Passing an explicit level to `build_new` or `character_set` also enables point-budget enforcement for that level.
- Once a level constraint is set, item additions reject items above that level unless `allow_requirement_violation=true` is supplied.
- Explicitly setting a level disables PoB's automatic level mode, so allocating passives will not overwrite the level.
- Build share codes use zlib plus URL-safe Base64, handled inside the server.
- Relative paths in `build_import` and `build_export` are resolved from the repository root.
- Ranked passive/item suggestions are planned next; `calc_what_if` already exposes the underlying misc calculator for safe comparisons.
- The transport is isolated in `mcp/stdio.lua`, so an HTTP transport can be added without changing the tools.

## Tests

From the repository root:

```sh
luajit tools/pob-mcp/tests/run.lua
luajit tools/pob-mcp/tests/stdio_test.lua
```

The first suite checks build mutation, passives, masteries, jewels, items, config, calculations, snapshots, and build-code round-trips. The second suite drives the real MCP stdio protocol, including initialization, tool listing, tool calls, error responses, parse errors, and a build-code reload.

## Layout

```
tools/pob-mcp/
  pob-mcp                 launcher
  main.lua                path resolution, lazy engine, stdio loop
  engine/
    bootstrap.lua         headless PoB boot and compatibility shims
    api.lua               build, passives, skills, items, config, calc
    codec.lua             zlib FFI and share-code encoding
    util.lua              sanitisation and formatting helpers
  mcp/
    protocol.lua          MCP methods and tool dispatch
    stdio.lua             newline-delimited JSON transport
    json.lua              dkjson wrapper
    schema.lua            JSON Schema helpers
  tools/                  tool definitions and handlers by domain
  tests/                  engine and stdio integration tests
```

The implementation lives outside `src/`, so the existing PoB test suite and update manifest are unaffected.
