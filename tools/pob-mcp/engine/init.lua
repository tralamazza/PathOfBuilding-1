local M = {}

local api

function M.get(options)
	options = options or {}
	if not api then
		local bootstrap = require("engine.bootstrap")
		local codec = require("engine.codec")
		local root = options.root or error("Missing PoB root path", 0)
		options.root = root
		options.src = options.src or (root .. "/src")
		options.runtime = options.runtime or (root .. "/runtime")
		options.userPath = options.userPath or ((os.getenv("HOME") or os.getenv("USERPROFILE") or root) .. "/.pob-mcp")
		codec.setRuntimePath(options.runtime)
		local env = bootstrap.boot(options)
		api = require("engine.api").new(env)
	end
	return api
end

return M
