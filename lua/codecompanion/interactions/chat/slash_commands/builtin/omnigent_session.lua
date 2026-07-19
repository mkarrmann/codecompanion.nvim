--=============================================================================
-- /omnigent_session -- show the current durable Omnigent session's metadata.
--=============================================================================

local utils = require("codecompanion.utils")

---@class CodeCompanion.SlashCommand.OmnigentSession: CodeCompanion.SlashCommand
local SlashCommand = {}

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
  if not chat.omnigent_session or not chat.omnigent_session.session_id then
    return false, "No active Omnigent session yet (submit a message or resume one first)"
  end
  return true, ""
end

---@return nil
function SlashCommand:execute()
  local s = self.Chat.omnigent_session
  if not s or not s.session_id then
    return utils.notify("No active Omnigent session", vim.log.levels.WARN)
  end
  local lines = {
    "Session:   " .. tostring(s.session_id),
    "Agent:     " .. tostring(s.agent_id or "?"),
    "Agent name:" .. tostring(s.agent_name and (" " .. s.agent_name) or " ?"),
    "Harness:   " .. tostring(s.harness or "?"),
    "Host:      " .. tostring(s.host_id or "(server-local)"),
    "Workspace: " .. tostring(s.workspace or "(none)"),
    "Status:    " .. tostring(s.status or "?"),
    "Model:     " .. tostring(s.model_override or s.model or "default"),
    "Streaming: " .. tostring(s:streaming()),
  }
  if s.reasoning_effort then
    lines[#lines + 1] = "Effort:    " .. tostring(s.reasoning_effort)
  end
  if type(s.usage) == "table" and s.usage.context_tokens then
    local ctx = tostring(s.usage.context_tokens)
    if s.usage.context_window then
      ctx = ctx .. " / " .. tostring(s.usage.context_window)
    end
    lines[#lines + 1] = "Context:   " .. ctx .. " tokens"
  end
  if type(s.codex_goal) == "table" then
    local usage = tostring(s.codex_goal.tokens_used or 0)
    if s.codex_goal.token_budget then
      usage = usage .. " / " .. tostring(s.codex_goal.token_budget)
    end
    lines[#lines + 1] = "Goal:      " .. tostring(s.codex_goal.status or "?") .. " (" .. usage .. " tokens)"
  end
  utils.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

return SlashCommand
