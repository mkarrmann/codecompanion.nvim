--=============================================================================
-- Omnigent sessionful controller (Milestone 6)
--
-- Implements the sessionful-adapter contract (see chat/sessionful.lua) for the
-- omnigent family. It is the single seam between the generic chat dispatch and
-- the omnigent runtime (session + handler + observer): the chat calls these,
-- never the omnigent internals directly. Stateless -- all per-session state lives
-- on the chat (`chat.omnigent_session` / `omnigent_session_id` / observer).
--=============================================================================

local M = {}

---Post a new foreground turn. Returns a request handle (or nil for a no-op /
---error, which the handler surfaces itself).
---@param chat CodeCompanion.Chat
---@param payload table
---@return table|nil
function M.submit(chat, payload)
  local handler = require("codecompanion.interactions.chat.omnigent.handler").new(chat)
  return handler:submit(payload)
end

---Resume an existing durable session into the chat (load + hydrate, no post).
---@param chat CodeCompanion.Chat
---@param session_id? string
---@return boolean ok, table|nil err
function M.resume(chat, session_id)
  if session_id then
    chat.omnigent_session_id = session_id
    chat.omnigent_session = nil
  end
  local handler = require("codecompanion.interactions.chat.omnigent.handler").new(chat)
  return handler:resume()
end

---Create or attach an Omnigent session without posting a chat message.
---@param chat CodeCompanion.Chat
---@return boolean ok, table|nil err
function M.ensure_session(chat)
  local handler = require("codecompanion.interactions.chat.omnigent.handler").new(chat)
  return handler:ensure_session({ foreground = false })
end

---Change the session model (delegates to the adapter family set_model).
---@param chat CodeCompanion.Chat
---@param model string
function M.set_model(chat, model)
  return require("codecompanion.adapters").set_model({
    omnigent_session = chat.omnigent_session,
    adapter = chat.adapter,
    model = model,
  })
end

---Tear down local resources for the chat (the durable server session lives on).
---@param chat CodeCompanion.Chat
function M.close(chat)
  if chat.omnigent_session then
    chat.omnigent_session:stop_stream()
  end
end

---Metadata snapshot for update_metadata / external UI. Returns nil if no session.
---@param chat CodeCompanion.Chat
---@return table|nil
function M.session_meta(chat)
  local s = chat.omnigent_session
  if not s then
    return nil
  end
  local pending = 0
  if type(s.pending_elicitations) == "table" then
    pending = vim.tbl_count(s.pending_elicitations)
  end
  return {
    session_id = s.session_id,
    agent_id = s.agent_id,
    agent_name = s.agent_name,
    harness = s.harness,
    labels = s.labels,
    host_id = s.host_id,
    workspace = s.workspace,
    status = s.status,
    reasoning_effort = s.reasoning_effort,
    usage = s.usage,
    pending_elicitations = pending,
    streaming = s:streaming(),
    model = s.model_override or s.model or "default",
    codex_goal = s.codex_goal,
  }
end

return M
