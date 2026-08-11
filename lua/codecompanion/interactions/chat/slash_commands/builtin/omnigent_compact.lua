--=============================================================================
-- /omnigent_compact -- ask the server to compact this session's context.
--
-- Thin wrapper over the compaction module: it owns the guards, the progress
-- indicator and the transcript marker, so this only has to route and report a
-- refusal. Everything else lands asynchronously when the server reports back.
--=============================================================================

local utils = require("codecompanion.utils")

---@class CodeCompanion.SlashCommand.OmnigentCompact: CodeCompanion.SlashCommand
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
  local ok, err = self.Chat:compact_omnigent()
  if not ok then
    utils.notify("Cannot compact: " .. ((err and err.message) or "unknown error"), vim.log.levels.WARN)
  end
end

return SlashCommand
