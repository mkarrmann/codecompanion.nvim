local h = require("tests.helpers")
local new_set = MiniTest.new_set

local T = new_set()

T["harness works"] = function()
  h.eq(1 + 1, 2)
end

T["codecompanion.config loads without tree-sitter"] = function()
  local config = require("codecompanion.config")
  h.eq(type(config), "table")
  h.eq(type(config.adapters), "table")
end

return T
