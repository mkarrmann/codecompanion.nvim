local h = require("tests.helpers")
local new_set = MiniTest.new_set

local adapters = require("codecompanion.adapters")

local T = new_set()

T["config registers the omnigent family"] = function()
  local config = require("codecompanion.config")
  h.eq(type(config.adapters.omnigent), "table")
  h.eq(config.adapters.omnigent.omnigent, "default")
end

T["resolves the generic omnigent adapter"] = function()
  local a = adapters.resolve("omnigent")
  h.eq(a.type, "omnigent")
  h.eq(a.name, "omnigent")
  h.eq(a.url, "http://127.0.0.1:6767")
  h.eq(a.defaults.host, "auto")
  h.eq(a.defaults.workspace, "auto")
  h.is_true(adapters.resolved(a))
end

T["resolves from a table spec"] = function()
  local a = adapters.resolve({ name = "omnigent" })
  h.eq(a.type, "omnigent")
  h.eq(a.name, "omnigent")
end

T["extend overrides url and merges defaults"] = function()
  local base = adapters.resolve("omnigent")
  local e = require("codecompanion.adapters.omnigent").extend(base, {
    url = "http://devserver-tunnel:9999",
    defaults = { agent = "polly" },
  })
  h.eq(e.url, "http://devserver-tunnel:9999")
  h.eq(e.defaults.agent, "polly")
  -- Untouched defaults are preserved.
  h.eq(e.defaults.host, "auto")
  h.eq(e.type, "omnigent")
end

T["make_safe returns a serialisable subset"] = function()
  local safe = adapters.make_safe(adapters.resolve("omnigent"))
  h.eq(safe.type, "omnigent")
  h.eq(safe.name, "omnigent")
  h.eq(safe.url, "http://127.0.0.1:6767")
  h.eq(type(safe.defaults), "table")
end

T["set_model stashes model_override without a session"] = function()
  local a = adapters.resolve("omnigent")
  adapters.set_model({ adapter = a, model = "claude-opus-4-8" })
  h.eq(a.defaults.model_override, "claude-opus-4-8")
end

T["set_model delegates to a live session when present"] = function()
  local a = adapters.resolve("omnigent")
  local got
  adapters.set_model({
    adapter = a,
    model = "claude-sonnet-5",
    omnigent_session = {
      set_model = function(_, m)
        got = m
        return true
      end,
    },
  })
  h.eq(got, "claude-sonnet-5")
end

T["resolve applies opts.model as model_override"] = function()
  local a = adapters.resolve("omnigent", { model = "gpt-5-5" })
  h.eq(a.defaults.model_override, "gpt-5-5")
end

-- ---- picker plumbing ------------------------------------------------------

T["adapter picker includes omnigent and drops container keys"] = function()
  local ca = require("codecompanion.interactions.chat.keymaps.change_adapter")
  local list = ca.get_adapters_list("anthropic")
  h.is_true(vim.tbl_contains(list, "omnigent"))
  h.is_false(vim.tbl_contains(list, "extend"))
  h.is_false(vim.tbl_contains(list, "opts"))
  h.is_false(vim.tbl_contains(list, "acp"))
end

T["list_omnigent_models reads the session snapshot"] = function()
  local ca = require("codecompanion.interactions.chat.keymaps.change_adapter")
  h.eq(ca.list_omnigent_models({}), nil)
  h.eq(ca.list_omnigent_models({ omnigent_session = { model_options = {} } }), nil)
  local models = ca.list_omnigent_models({
    omnigent_session = { model_options = { { value = "a", name = "A" }, { value = "b", name = "B" } } },
  })
  h.eq(#models, 2)
end

return T
