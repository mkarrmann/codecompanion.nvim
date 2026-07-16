--=============================================================================
-- Omnigent chat command helpers
--
-- Small glue used by the omnigent slash commands (and reusable by external
-- resume UX): build a REST client for a chat's omnigent adapter, reusing the
-- live session's client when one already exists so URL/headers stay consistent.
--=============================================================================

local M = {}

---Build (or reuse) an omnigent REST client for a chat.
---@param chat CodeCompanion.Chat
---@return CodeCompanion.Omnigent.Client
function M.client_for(chat)
  if chat.omnigent_session and chat.omnigent_session.client then
    return chat.omnigent_session.client
  end
  local adapter = chat.adapter or {}
  return require("codecompanion.omnigent.client").new({
    url = adapter.url,
    headers = (adapter.env and adapter.env.headers) or nil,
  })
end

return M
