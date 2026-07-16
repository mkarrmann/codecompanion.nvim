--=============================================================================
-- /omnigent_children -- list the child (sub-agent) sessions spawned by the
-- current durable session (surfaced from session.child_session.updated events).
--=============================================================================

local utils = require("codecompanion.utils")

---@class CodeCompanion.SlashCommand.OmnigentChildren: CodeCompanion.SlashCommand
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
    return false, "No active Omnigent session yet"
  end
  return true, ""
end

---@return nil
function SlashCommand:execute()
  local s = self.Chat.omnigent_session
  local children = s and s.child_sessions or {}
  local lines = {}
  for id, c in pairs(children) do
    c = c or {}
    local title = c.title or c.session_name or id
    local status = c.current_task_status or (c.busy and "busy") or "?"
    lines[#lines + 1] = string.format("%s  [%s]  %s", title, status, id)
  end
  if #lines == 0 then
    return utils.notify("No child sessions for this Omnigent session", vim.log.levels.INFO)
  end
  table.sort(lines)
  utils.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

return SlashCommand
