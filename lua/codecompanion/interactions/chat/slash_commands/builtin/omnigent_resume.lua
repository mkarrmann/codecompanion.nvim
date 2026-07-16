--=============================================================================
-- /omnigent_resume -- list durable Omnigent sessions and resume the chosen one
-- into the current chat (loads snapshot + history, posts nothing). Must be run
-- before submitting a turn, mirroring the ACP /resume constraint.
--=============================================================================

local utils = require("codecompanion.utils")
local sessions_lib = require("codecompanion.interactions.chat.omnigent.sessions")

---@class CodeCompanion.SlashCommand.OmnigentResume: CodeCompanion.SlashCommand
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
  return true, ""
end

---@return nil
function SlashCommand:execute()
  local Chat = self.Chat

  if Chat.cycle > 1 then
    return utils.notify("The resume command must be called before submitting any messages", vim.log.levels.WARN)
  end

  local commands = require("codecompanion.interactions.chat.omnigent.commands")
  local client = commands.client_for(Chat)

  local page = (self.config.opts and self.config.opts.max_sessions) or 100
  local list, err = client:list_sessions({ limit = page })
  if not list then
    return utils.notify("Failed to list Omnigent sessions: " .. (err and err.message or "?"), vim.log.levels.ERROR)
  end

  list = sessions_lib.by_recency(sessions_lib.active(list))
  if #list == 0 then
    return utils.notify("No Omnigent sessions found", vim.log.levels.INFO)
  end

  local choices, map = {}, {}
  for i, s in ipairs(list) do
    choices[i] = sessions_lib.format_summary(s)
    map[i] = s
  end

  vim.ui.select(choices, {
    prompt = "Resume Omnigent Session",
    kind = "codecompanion.nvim",
  }, function(_, idx)
    if not idx then
      return
    end
    local sel = map[idx]
    local ok, rerr = Chat:resume_omnigent(sel.id)
    if ok then
      if sel.title and sel.title ~= "" then
        Chat:set_title(sel.title)
      end
      utils.fire("OmnigentChatRestored", {
        bufnr = Chat.bufnr,
        id = Chat.id,
        session_id = sel.id,
        title = Chat.title,
      })
      utils.notify("Resumed session: " .. (sel.title or sel.id), vim.log.levels.INFO)
    else
      utils.notify("Failed to resume: " .. (rerr and rerr.message or "?"), vim.log.levels.ERROR)
    end
  end)
end

return SlashCommand
