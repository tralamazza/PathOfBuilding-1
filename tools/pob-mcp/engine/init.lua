local M = {}

local api

function M.get(options)
	if not api then
		local bootstrap = require("engine.bootstrap")
		local codec = require("engine.codec")
		codec.setRuntimePath(options.runtime)
		local env = bootstrap.boot(options)
		api = require("engine.api").new(env)
	end
	return api
end

return M
