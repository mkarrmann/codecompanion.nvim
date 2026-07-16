--=============================================================================
-- Omnigent chat handler (foreground turn)
--
-- Analogous to the ACP handler, but not derived from it. For a user submit it:
--   1. ensures an omnigent session (create or load + hydrate), FAIL-CLOSED on host
--   2. announces the request lifecycle (RequestStarted) BEFORE streaming/posting,
--      so a fast terminal event can never race ahead of request_id
--   3. opens the SSE stream BEFORE posting (the stream is live-tail, not replay)
--   4. posts ONLY the unsent user content as a message event
--   5. streams live events to the buffer via the session's on_update callback
--   6. completes the request on a terminal event and DETACHES from the session so
--      later (background/wakeup) events never render through a finished handler
--
-- Assistant text is accumulated in `self.output` and handed to chat:done(), which
-- persists the transcript message. Cancellation posts an interrupt (it does NOT
-- stop or delete the durable session).
--
-- Background/wakeup turns (rendering events while no foreground request is active)
-- are Milestone 4 and are intentionally NOT handled here; this handler only owns
-- the lifetime of one foreground turn and unbinds itself when that turn ends.
--=============================================================================

local Session = require("codecompanion.omnigent.session")
local config = require("codecompanion.config")
local log = require("codecompanion.utils.log")
local utils = require("codecompanion.utils")

---@class CodeCompanion.Chat.OmnigentHandler
---@field chat CodeCompanion.Chat
---@field output string[]
---@field reasoning string[]
---@field request_id? string
---@field _done boolean
local OmnigentHandler = {}
OmnigentHandler.__index = OmnigentHandler

---@param chat CodeCompanion.Chat
---@return CodeCompanion.Chat.OmnigentHandler
function OmnigentHandler.new(chat)
  return setmetatable({ chat = chat, output = {}, reasoning = {}, _done = false }, OmnigentHandler)
end

---Ensure a live session runtime exists (create new or load + hydrate existing) and
---bind its update/error callbacks to THIS handler (stored so we can detach later).
---@return boolean ok, table|nil err
function OmnigentHandler:ensure_session()
  local chat = self.chat
  if not chat.omnigent_session then
    chat.omnigent_session = Session.new({ adapter = chat.adapter, callbacks = {} })
  end
  local session = chat.omnigent_session

  self._on_update = function(u)
    self:on_update(u)
  end
  self._on_error = function(e)
    self:on_error(e)
  end
  session.callbacks.on_update = self._on_update
  session.callbacks.on_error = self._on_error

  if session.session_id then
    return true
  end

  if chat.omnigent_session_id then
    local r, err = session:load(chat.omnigent_session_id)
    if not r then
      return false, err
    end
    self:_hydrate(r.items)
  else
    local sess, err = session:create()
    if not sess then
      return false, err
    end
  end

  chat.omnigent_session_id = session.session_id
  if chat.update_metadata then
    pcall(function()
      chat:update_metadata()
    end)
  end
  utils.fire("OmnigentSessionReady", { bufnr = chat.bufnr, session_id = session.session_id })
  return true
end

---Hydrate the chat transcript + buffer from durable items (resume path). Items
---are marked sent so they are never re-posted to the server.
---@param items table[]
---@return integer count
function OmnigentHandler:_hydrate(items)
  local render = require("codecompanion.interactions.chat.omnigent.render")
  local MT = self.chat.MESSAGE_TYPES
  local msgs = render.snapshot_messages(items or {})
  for _, m in ipairs(msgs) do
    if self.chat.add_message then
      self.chat:add_message({ role = m.role, content = m.content }, { _meta = { sent = true } })
    end
    if self.chat.add_buf_message then
      -- Render with the role-appropriate buffer type so user turns aren't drawn
      -- as LLM output.
      local mtype = (m.role == config.constants.USER_ROLE) and MT.USER_MESSAGE or MT.LLM_MESSAGE
      self.chat:add_buf_message({ role = m.role, content = m.content }, { type = mtype })
    end
  end
  return #msgs
end

---Resume a saved session: load + hydrate history WITHOUT posting a turn. This is
---the correct entry for opening a session to view/continue (used by the M3 resume
---command); submit() is only for posting a new turn.
---@return boolean ok, table|nil err
function OmnigentHandler:resume()
  local ok, err = self:ensure_session()
  self:_detach() -- no active foreground request while merely attached
  if not ok then
    self.chat.status = "error"
    self:_render_error(err or "Failed to resume omnigent session")
  end
  if self.chat.ready_for_input then
    self.chat:ready_for_input()
  end
  return ok, err
end

---Collect the unsent user message content and the messages to mark sent.
---Mirrors ACP's "send only new user messages" behaviour rather than resending
---the whole transcript (omnigent already holds durable history).
---@return string text, table[] marked
function OmnigentHandler:_unsent_user_text()
  local parts, marked = {}, {}
  for _, m in ipairs(self.chat.messages or {}) do
    if
      m.role == config.constants.USER_ROLE
      and (not m._meta or not m._meta.sent)
      and type(m.content) == "string"
      and m.content ~= ""
    then
      parts[#parts + 1] = m.content
      marked[#marked + 1] = m
    end
  end
  return table.concat(parts, "\n\n"), marked
end

---@param marked table[]
function OmnigentHandler:_mark_sent(marked)
  for _, m in ipairs(marked) do
    m._meta = m._meta or {}
    m._meta.sent = true
  end
end

---Submit a foreground turn.
---@param payload table
---@return table|nil request handle
function OmnigentHandler:submit(payload)
  local ok, err = self:ensure_session()
  if not ok then
    -- No request was started; just surface the error and finish.
    self.chat.status = "error"
    self:_render_error(err or "Failed to establish omnigent session")
    self:_detach()
    self.chat:done(self.output)
    return nil
  end

  local session = self.chat.omnigent_session

  local text, marked = self:_unsent_user_text()
  if not text or text == "" then
    -- Not an error. This is a bare resume (history hydrated, no new prompt) or a
    -- blank submit: don't post, don't mark the chat failed -- detach and hand
    -- control back to the user.
    log:debug("[Omnigent::Handler] Nothing to submit; ready for input")
    self:_detach()
    if self.chat.ready_for_input then
      self.chat:ready_for_input()
    end
    return nil
  end

  -- Announce the request lifecycle BEFORE opening the stream / posting, so a fast
  -- terminal event delivered on the stream can never reach _complete() before
  -- request_id exists (which would drop RequestFinished and desync the queue).
  self.request_id = tostring(math.random(10000000))
  utils.fire("RequestStarted", {
    id = self.request_id,
    bufnr = self.chat.bufnr,
    adapter = {
      name = self.chat.adapter.name,
      formatted_name = self.chat.adapter.formatted_name,
      type = "omnigent",
    },
  })

  -- Open the stream BEFORE posting: it is live-tail, not a replay source.
  session:start_stream()

  local res, perr = session:post_message(text)
  if not res then
    self:_render_error(perr or "Failed to post message")
    self:_complete("error") -- fires RequestFinished + chat:done + detaches
    return nil
  end
  self:_mark_sent(marked)

  return {
    session_id = session.session_id,
    status = function()
      return session.status
    end,
    cancel = function()
      pcall(function()
        session:interrupt()
      end)
    end,
  }
end

---Handle a normalised session update (live foreground turn).
---@param u CodeCompanion.Omnigent.Update
function OmnigentHandler:on_update(u)
  local C = config.constants
  local MT = self.chat.MESSAGE_TYPES
  local k = u.kind

  if k == "message_delta" then
    table.insert(self.output, u.delta)
    self.chat:add_buf_message({ role = C.LLM_ROLE, content = u.delta }, { type = MT.LLM_MESSAGE })
  elseif k == "reasoning_delta" then
    table.insert(self.reasoning, u.delta)
    if config.display.chat.show_reasoning then
      self.chat:add_buf_message({ role = C.LLM_ROLE, content = u.delta }, { type = MT.REASONING_MESSAGE })
    end
  elseif k == "elicitation" then
    -- Full native elicitation handling is Milestone 5. Until then, do NOT let a
    -- foreground turn silently hang waiting on an approval: surface it and point
    -- the user at the Omnigent UI. (We never auto-approve.)
    self.chat:add_buf_message({
      role = C.LLM_ROLE,
      content = "\n> [!WARNING] Omnigent is waiting for an approval/elicitation. "
        .. "Native elicitation handling is not implemented yet — resolve it in the Omnigent UI.\n",
    }, { type = MT.SYSTEM_MESSAGE or MT.LLM_MESSAGE })
  elseif k == "turn_completed" then
    self:_complete("success")
  elseif k == "turn_failed" or k == "error" then
    self:_render_error(u.error or "omnigent turn failed")
    self:_complete("error")
  elseif k == "interrupted" or k == "turn_cancelled" then
    self:_complete("cancelled")
  elseif k == "status" or k == "usage" or k == "model" then
    if self.chat.update_metadata then
      pcall(function()
        self.chat:update_metadata()
      end)
    end
  end
  -- child_session / other: surfaced in M5.
end

---@param err table|string
function OmnigentHandler:on_error(err)
  self:_render_error(err)
  self:_complete("error")
end

---Unbind this handler from the session so post-completion (background/wakeup)
---events do not render through a finished foreground handler. Only detaches if the
---session still points at THIS handler's callbacks (a newer submit may have
---rebound them).
function OmnigentHandler:_detach()
  local s = self.chat.omnigent_session
  if s and s.callbacks then
    if s.callbacks.on_update == self._on_update then
      s.callbacks.on_update = nil
    end
    if s.callbacks.on_error == self._on_error then
      s.callbacks.on_error = nil
    end
  end
end

---Complete the CodeCompanion request exactly once.
---@param status string
function OmnigentHandler:_complete(status)
  if self._done then
    return
  end
  self._done = true
  self:_detach()
  if not self.chat.status or self.chat.status == "" then
    self.chat.status = status
  end
  if self.request_id then
    utils.fire("RequestFinished", {
      id = self.request_id,
      bufnr = self.chat.bufnr,
      status = self.chat.status,
    })
  end
  self.chat:done(self.output, self.reasoning, {})
end

---@param err table|string
function OmnigentHandler:_render_error(err)
  local msg = type(err) == "table" and (err.message or vim.inspect(err)) or tostring(err)
  log:error("[Omnigent::Handler] %s", msg)
  self.chat:add_buf_message(
    { role = config.constants.LLM_ROLE, content = string.format("```txt\n%s\n```", msg) },
    { type = self.chat.MESSAGE_TYPES.LLM_MESSAGE }
  )
end

return OmnigentHandler
