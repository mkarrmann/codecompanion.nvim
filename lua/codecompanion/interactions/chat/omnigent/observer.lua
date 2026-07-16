--=============================================================================
-- Omnigent passive observer (Milestone 4)
--
-- The persistent consumer of a session's normalised updates while NO foreground
-- request is active. Durable omnigent sessions keep streaming after a turn (and
-- can be driven from elsewhere -- an external client, a scheduled wakeup, the
-- meta-harness). The foreground handler owns the stream only for the lifetime of
-- one user-initiated turn; the observer renders everything else -- "background
-- turns" -- into the chat buffer so the editor passively reflects the session.
--
-- Arbitration is handled by the session's stream router: while a foreground
-- callback is bound the observer is dormant; the moment the handler detaches, the
-- observer becomes the sink again. So the observer never has to reason about
-- whether a foreground turn is active -- it only sees updates it owns.
--
-- Rendering tracks ONE current turn (omnigent runs a single response at a time),
-- not a per-response-id map: the deployed harness streams assistant text as
-- id-less deltas (rid "__live__") but reports `response.completed` with a real
-- `resp_` id, so a strict per-id model would never match the two phases. Rendering
-- is CONTENT-BASED: the observer appends only the new suffix beyond what it has
-- already shown, so a reconnect replay (which the server re-sends whole on /stream
-- subscribe) never double-renders. A `turn_started` while a partial is already
-- open is treated as a continuation (the reconnect-replay case), not a new turn.
--=============================================================================

local config = require("codecompanion.config")
local log = require("codecompanion.utils.log")
local utils = require("codecompanion.utils")

---@class CodeCompanion.Chat.OmnigentObserver
---@field chat CodeCompanion.Chat
---@field _cur? { rid?: string, shown: string, header: boolean } current background turn
local Observer = {}
Observer.__index = Observer

---@param chat CodeCompanion.Chat
---@return CodeCompanion.Chat.OmnigentObserver
function Observer.new(chat)
  return setmetatable({ chat = chat, _cur = nil }, Observer)
end

---True if a background turn is currently mid-render (unfinalised).
---@return boolean
function Observer:has_partial()
  return self._cur ~= nil
end

---Ensure a current turn exists (opening one lazily for a stray delta).
---@param rid? string
function Observer:_ensure_turn(rid)
  if not self._cur then
    self._cur = { rid = rid, shown = "", header = false }
  elseif rid then
    -- Continuation (e.g. reconnect replay retargets the response id): keep the
    -- text we've already shown; only update the id we're tracking.
    self._cur.rid = rid
  end
end

---Write the distinct one-line marker before a background turn's first content.
function Observer:_ensure_header()
  if not self._cur or self._cur.header then
    return
  end
  self._cur.header = true
  local MT = self.chat.MESSAGE_TYPES
  self.chat:add_buf_message({
    role = config.constants.LLM_ROLE,
    content = "\n> [!NOTE] Omnigent background activity\n",
  }, { type = MT.SYSTEM_MESSAGE or MT.LLM_MESSAGE })
  utils.fire("ChatOmnigentWakeup", {
    bufnr = self.chat.bufnr,
    id = self.chat.id,
    session_id = self.chat.omnigent_session_id,
    response_id = self._cur.rid,
  })
end

---Render the new suffix of the current background turn's text (content-dedup safe).
---@param full string full accumulated text for the current turn
function Observer:_render_text(full)
  local cur = self._cur
  if not cur then
    return
  end
  local shown = cur.shown
  if #full <= #shown then
    return
  end
  local suffix
  if full:sub(1, #shown) == shown then
    suffix = full:sub(#shown + 1)
  else
    -- Divergent replay (shouldn't happen with reset_inflight); render whole.
    suffix = full
  end
  self:_ensure_header()
  self.chat:add_buf_message(
    { role = config.constants.LLM_ROLE, content = suffix },
    { type = self.chat.MESSAGE_TYPES.LLM_MESSAGE }
  )
  cur.shown = full
end

---Commit the finished background turn to the transcript (so it persists and is
---never re-posted) and fire the background-turn autocmd.
function Observer:_finalize()
  local cur = self._cur
  self._cur = nil
  if not cur then
    return
  end
  if cur.shown ~= "" and self.chat.add_message then
    self.chat:add_message(
      { role = config.constants.LLM_ROLE, content = cur.shown },
      { _meta = { sent = true, omnigent_background = true } }
    )
  end
  utils.fire("ChatOmnigentBackgroundTurn", {
    bufnr = self.chat.bufnr,
    id = self.chat.id,
    session_id = self.chat.omnigent_session_id,
    response_id = cur.rid,
    content = cur.shown,
  })
end

---Handle one normalised session update (only called when no foreground is bound).
---@param u CodeCompanion.Omnigent.Update
function Observer:handle_update(u)
  local C = config.constants
  local MT = self.chat.MESSAGE_TYPES
  local k = u.kind

  if k == "turn_started" then
    self:_ensure_turn(u.response_id)
  elseif k == "message_delta" then
    self:_ensure_turn(u.response_id)
    self:_render_text(u.text or (self._cur.shown .. (u.delta or "")))
  elseif k == "reasoning_delta" then
    if config.display.chat.show_reasoning then
      self.chat:add_buf_message({ role = C.LLM_ROLE, content = u.delta }, { type = MT.REASONING_MESSAGE })
    end
  elseif k == "item_committed" then
    -- Externally-injected USER messages (driven from another client) should
    -- appear so the transcript stays coherent. Assistant text is already covered
    -- by the streamed deltas; tool calls get a compact marker.
    if u.item_type == "message" and u.role == "user" and type(u.text) == "string" and u.text ~= "" then
      self.chat:add_buf_message({ role = C.USER_ROLE, content = u.text }, { type = MT.USER_MESSAGE })
      if self.chat.add_message then
        self.chat:add_message({ role = C.USER_ROLE, content = u.text }, { _meta = { sent = true } })
      end
    elseif u.item_type == "function_call" then
      local render = require("codecompanion.interactions.chat.omnigent.render")
      self.chat:add_buf_message(
        { role = C.LLM_ROLE, content = render.tool_call_line(u.item or { name = u.tool_name }) },
        { type = MT.SYSTEM_MESSAGE or MT.LLM_MESSAGE }
      )
    end
  elseif k == "elicitation" then
    -- A background turn is waiting on approval; present it (we are the authority).
    require("codecompanion.interactions.chat.omnigent.elicitation").handle(
      self.chat,
      self.chat.omnigent_session,
      u
    )
  elseif k == "child_session" or k == "child_session_created" then
    local render = require("codecompanion.interactions.chat.omnigent.render")
    self.chat:add_buf_message(
      { role = C.LLM_ROLE, content = render.child_session_line(u) },
      { type = MT.SYSTEM_MESSAGE or MT.LLM_MESSAGE }
    )
  elseif k == "policy_denied" then
    local render = require("codecompanion.interactions.chat.omnigent.render")
    self.chat:add_buf_message(
      { role = C.LLM_ROLE, content = render.policy_denied_line(u) },
      { type = MT.SYSTEM_MESSAGE or MT.LLM_MESSAGE }
    )
  elseif k == "turn_completed" then
    self:_fire_usage(u.usage)
    self:_finalize()
  elseif k == "turn_failed" or k == "error" then
    local msg = type(u.error) == "table" and (u.error.message or vim.inspect(u.error)) or tostring(u.error)
    self.chat:add_buf_message(
      { role = C.LLM_ROLE, content = string.format("\n> [!WARNING] Omnigent background turn failed: %s\n", msg) },
      { type = MT.SYSTEM_MESSAGE or MT.LLM_MESSAGE }
    )
    self._cur = nil
  elseif k == "interrupted" or k == "turn_cancelled" then
    self:_finalize()
  elseif k == "status" or k == "usage" or k == "model" then
    if k == "usage" then
      self:_fire_usage(u.usage)
    end
    if self.chat.update_metadata then
      pcall(function()
        self.chat:update_metadata()
      end)
    end
  end
  -- other: intentionally not rendered in the background stream.
end

---Fire a transport-neutral usage event (mirrors the foreground handler) so the
---winbar stats update from background turns too.
---@param usage any
function Observer:_fire_usage(usage)
  local render = require("codecompanion.interactions.chat.omnigent.render")
  utils.fire("OmnigentUsage", {
    bufnr = self.chat.bufnr,
    session_id = self.chat.omnigent_session_id,
    usage = render.enrich_usage(usage, self.chat.omnigent_session),
  })
end

---Render a durable item fetched during reconnect reconcile (see Session:_reconcile).
---Only message items are rendered; already-seen items are filtered by the caller.
---@param item table
function Observer:reconcile_item(item)
  local render = require("codecompanion.interactions.chat.omnigent.render")
  local msg = render.durable_item_to_message(item)
  if not msg then
    return
  end
  local MT = self.chat.MESSAGE_TYPES
  local mtype = (msg.role == config.constants.USER_ROLE) and MT.USER_MESSAGE or MT.LLM_MESSAGE
  self.chat:add_buf_message(
    { role = config.constants.LLM_ROLE, content = "\n> [!NOTE] Omnigent (recovered)\n" },
    { type = MT.SYSTEM_MESSAGE or MT.LLM_MESSAGE }
  )
  self.chat:add_buf_message({ role = msg.role, content = msg.content }, { type = mtype })
  if self.chat.add_message then
    self.chat:add_message({ role = msg.role, content = msg.content }, { _meta = { sent = true } })
  end
  log:debug("[Omnigent::Observer] reconciled missed item %s", tostring(item.id))
end

return Observer
