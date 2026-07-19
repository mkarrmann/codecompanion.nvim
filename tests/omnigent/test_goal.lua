local h = require("tests.helpers")
local new_set = MiniTest.new_set

local controller = require("codecompanion.interactions.chat.omnigent.controller")
local goal_command = require("codecompanion.interactions.chat.slash_commands.builtin.codex_goal")

local T = new_set()

T["is enabled only for configured or attached codex-native sessions"] = function()
  local configured = { adapter = { type = "omnigent", defaults = { agent = "codex-native-ui" } } }
  h.eq(goal_command.enabled(configured), true)

  local unsupported = { adapter = { type = "omnigent", defaults = { agent = "codex" } } }
  h.eq(goal_command.enabled(unsupported), false)

  unsupported.omnigent_session = {
    session_id = "conv_1",
    supports_codex_goal = function()
      return true
    end,
  }
  h.eq(goal_command.enabled(unsupported), true)
end

T["refreshes state and pauses an active goal"] = function()
  local original_ensure = controller.ensure_session
  local original_select = vim.ui.select
  local selected_status
  local session = {
    supports_codex_goal = function()
      return true
    end,
    get_codex_goal = function(_, callback)
      callback({ objective = "finish", status = "active", tokens_used = 5, token_budget = 10 })
    end,
    set_codex_goal_status = function(_, status, callback)
      selected_status = status
      callback({ objective = "finish", status = status, tokens_used = 5, token_budget = 10 })
    end,
  }
  local chat = {
    adapter = { type = "omnigent", defaults = { agent = "codex-native-ui" } },
    omnigent_session = session,
  }
  controller.ensure_session = function()
    return true
  end
  vim.ui.select = function(items, _, callback)
    for _, item in ipairs(items) do
      if type(item) == "table" and item.label == "Pause goal" then
        callback(item)
        return
      end
    end
    callback(nil)
  end

  local ok, err = pcall(function()
    goal_command.new({ Chat = chat, config = {}, context = {} }):execute()
    h.eq(selected_status, "paused")
  end)
  controller.ensure_session = original_ensure
  vim.ui.select = original_select
  if not ok then
    error(err)
  end
end

T["creates a Goal as the first chat action"] = function()
  local original_ensure = controller.ensure_session
  local original_select = vim.ui.select
  local original_input = vim.ui.input
  local ensured = false
  local created
  local session = {
    supports_codex_goal = function()
      return true
    end,
    get_codex_goal = function(_, callback)
      callback(nil)
    end,
    set_codex_goal = function(_, goal, callback)
      created = goal
      callback({
        objective = goal.objective,
        status = goal.status,
        token_budget = nil,
        tokens_used = 0,
      })
    end,
  }
  local chat = {
    adapter = { type = "omnigent", defaults = { agent = "codex-native-ui" } },
    omnigent_session = session,
  }
  controller.ensure_session = function()
    ensured = true
    return true
  end
  local selections = { "Create goal", "active" }
  vim.ui.select = function(_, _, callback)
    callback(table.remove(selections, 1))
  end
  local inputs = { "Finish the migration", "" }
  vim.ui.input = function(_, callback)
    callback(table.remove(inputs, 1))
  end

  local ok, err = pcall(function()
    goal_command.new({ Chat = chat, config = {}, context = {} }):execute()
    h.eq(ensured, true)
    h.eq(created.objective, "Finish the migration")
    h.eq(created.status, "active")
    h.eq(created.token_budget, vim.NIL)
  end)
  controller.ensure_session = original_ensure
  vim.ui.select = original_select
  vim.ui.input = original_input
  if not ok then
    error(err)
  end
end

return T
