local modules = {
	"tools.build",
	"tools.passives",
	"tools.skills",
	"tools.items",
	"tools.config",
	"tools.calc",
}

local M = {}

local defs = {}
local handlers = {}

for _, moduleName in ipairs(modules) do
	local module = require(moduleName)
	for _, definition in ipairs(module.defs or {}) do
		defs[#defs + 1] = definition
	end
	for name, handler in pairs(module.handlers or {}) do
		handlers[name] = handler
	end
end

M.defs = defs
M.handlers = handlers

return M
