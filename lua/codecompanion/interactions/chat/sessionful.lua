--=============================================================================
-- Sessionful-adapter interface (Milestone 6)
--
-- CodeCompanion has three adapter families: `http` (stateless request/response),
-- `acp` (a local agent process over JSON-RPC), and `omnigent` (a durable,
-- server-owned session over REST + SSE). The latter two are "sessionful": a chat
-- buffer is bound to a long-lived session that survives individual turns, can be
-- resumed, and streams updates. This module defines the small contract those
-- controllers expose so `chat/init.lua` can dispatch generically instead of
-- growing per-family `if adapter.type == ...` branches for every operation.
--
-- A controller is a plain module of functions taking the chat as the first arg
-- (the chat already holds all per-session state), resolved by adapter type:
--
--   submit(chat, payload) -> request handle | nil   post a new foreground turn
--   resume(chat, id?)     -> ok, err                load + hydrate an existing session
--   set_model(chat, model)                          change the session model
--   close(chat)                                     tear down local resources (stream)
--   session_meta(chat)    -> table | nil            metadata for update_metadata/UI
--
-- ACP is intentionally NOT migrated onto this yet: its ~10 monkeypatches in the
-- user's config make it high-risk (see the roadmap). Only omnigent is registered,
-- so `is_sessionful` is false for acp/http and the existing branches stand.
--=============================================================================

local M = {}

---adapter.type -> controller module.
M.controllers = {
  omnigent = "codecompanion.interactions.chat.omnigent.controller",
}

---Resolve the sessionful controller for a chat (nil for http/acp).
---@param chat CodeCompanion.Chat
---@return table|nil
function M.for_chat(chat)
  local t = chat and chat.adapter and chat.adapter.type
  local path = t and M.controllers[t]
  if not path then
    return nil
  end
  return require(path)
end

---True if the chat's adapter has a registered sessionful controller.
---@param chat CodeCompanion.Chat
---@return boolean
function M.is_sessionful(chat)
  return M.for_chat(chat) ~= nil
end

return M
