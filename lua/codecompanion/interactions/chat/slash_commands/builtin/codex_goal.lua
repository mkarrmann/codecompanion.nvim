local controller = require("codecompanion.interactions.chat.omnigent.controller")
local utils = require("codecompanion.utils")

---@class CodeCompanion.SlashCommand.CodexGoal: CodeCompanion.SlashCommand
local SlashCommand = {}

local resumable_statuses = {
  paused = true,
  blocked = true,
  usageLimited = true,
  budgetLimited = true,
}

---@param args CodeCompanion.SlashCommand
function SlashCommand.new(args)
  return setmetatable({
    Chat = args.Chat,
    config = args.config,
    context = args.context,
  }, { __index = SlashCommand })
end

---@param chat CodeCompanion.Chat
---@return boolean, string
function SlashCommand.enabled(chat)
  if not chat.adapter or chat.adapter.type ~= "omnigent" then
    return false, "Requires an Omnigent adapter"
  end
  local session = chat.omnigent_session
  if session and session.session_id then
    return session:supports_codex_goal(), "Codex Goal requires a codex-native-ui session"
  end
  local defaults = chat.adapter.defaults or {}
  return defaults.agent == "codex-native-ui", "Select codex-native-ui before opening /goal"
end

---@param err table|string|nil
local function notify_error(err)
  local message = type(err) == "table" and err.message or tostring(err or "Unknown error")
  utils.notify("Codex Goal: " .. message, vim.log.levels.ERROR)
end

---@param goal table
---@return string
local function format_goal(goal)
  local tokens = tostring(goal.tokens_used or 0)
  if goal.token_budget then
    tokens = tokens .. " / " .. tostring(goal.token_budget)
  else
    tokens = tokens .. " / unlimited"
  end
  local elapsed = tonumber(goal.time_used_seconds) or 0
  return table.concat({
    "Status: " .. tostring(goal.status or "unknown"),
    "Tokens: " .. tokens,
    "Elapsed: " .. tostring(math.floor(elapsed)) .. "s",
    "",
    tostring(goal.objective or ""),
  }, "\n")
end

---@param session CodeCompanion.Omnigent.Session
---@param current? table
local function edit_goal(session, current)
  vim.ui.input({
    prompt = current and "Goal objective: " or "New goal objective: ",
    default = current and current.objective or nil,
  }, function(objective)
    if objective == nil then
      return
    end
    objective = vim.trim(objective)
    if objective == "" or vim.fn.strchars(objective) > 4000 then
      return notify_error("Objective must contain 1 to 4000 characters")
    end
    vim.ui.input({
      prompt = "Token budget (blank for unlimited): ",
      default = current and current.token_budget and tostring(current.token_budget) or "",
    }, function(raw_budget)
      if raw_budget == nil then
        return
      end
      local token_budget = vim.trim(raw_budget) == "" and vim.NIL or tonumber(raw_budget)
      if token_budget ~= vim.NIL and (not token_budget or token_budget <= 0 or token_budget % 1 ~= 0) then
        return notify_error("Token budget must be blank or a positive integer")
      end
      vim.ui.select({ "active", "paused" }, {
        prompt = "Goal status",
        kind = "codecompanion.nvim",
      }, function(status)
        if not status then
          return
        end
        session:set_codex_goal({
          objective = objective,
          token_budget = token_budget,
          status = status,
        }, function(goal, err)
          if err then
            return notify_error(err)
          end
          utils.notify(format_goal(goal), vim.log.levels.INFO)
        end)
      end)
    end)
  end)
end

---@param session CodeCompanion.Omnigent.Session
---@param goal table
local function select_existing_action(session, goal)
  local actions = {
    {
      label = "View goal",
      run = function()
        utils.notify(format_goal(goal), vim.log.levels.INFO)
      end,
    },
    {
      label = "Edit objective and budget",
      run = function()
        edit_goal(session, goal)
      end,
    },
  }
  if goal.status == "active" then
    actions[#actions + 1] = { label = "Pause goal", status = "paused" }
  elseif resumable_statuses[goal.status] then
    actions[#actions + 1] = { label = "Resume goal", status = "active" }
  end
  actions[#actions + 1] = { label = "Clear goal", clear = true }

  vim.ui.select(actions, {
    prompt = "Codex Goal",
    kind = "codecompanion.nvim",
    format_item = function(action)
      return action.label
    end,
  }, function(action)
    if not action then
      return
    end
    if action.run then
      return action.run()
    end
    if action.status then
      return session:set_codex_goal_status(action.status, function(updated, err)
        if err then
          return notify_error(err)
        end
        utils.notify(format_goal(updated), vim.log.levels.INFO)
      end)
    end
    vim.ui.select({ "Clear", "Cancel" }, {
      prompt = "Clear the current Codex Goal?",
      kind = "codecompanion.nvim",
    }, function(choice)
      if choice ~= "Clear" then
        return
      end
      session:clear_codex_goal(function(_, err)
        if err then
          return notify_error(err)
        end
        utils.notify("Codex Goal cleared", vim.log.levels.INFO)
      end)
    end)
  end)
end

---@return nil
function SlashCommand:execute()
  local ok, err = controller.ensure_session(self.Chat)
  if not ok then
    return notify_error(err)
  end
  local session = self.Chat.omnigent_session
  if not session:supports_codex_goal() then
    return notify_error("The attached session is not codex-native-ui")
  end
  session:get_codex_goal(function(goal, get_err)
    if get_err then
      return notify_error(get_err)
    end
    if goal then
      return select_existing_action(session, goal)
    end
    vim.ui.select({ "Create goal", "Cancel" }, {
      prompt = "No active Codex Goal",
      kind = "codecompanion.nvim",
    }, function(choice)
      if choice == "Create goal" then
        edit_goal(session)
      end
    end)
  end)
end

return SlashCommand
