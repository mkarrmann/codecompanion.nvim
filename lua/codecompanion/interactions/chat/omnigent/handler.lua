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
local render = require("codecompanion.interactions.chat.omnigent.render")
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
---
---ASYNCHRONOUS: creating a session is up to three round trips (agents, hosts,
---create) and loading one is two (snapshot, items). Blocking on either meant the
---editor was frozen for the whole of "open a chat", which is exactly when the
---user expects to be able to keep typing. The callback fires on the main loop.
---@param opts? table { foreground?: boolean }
---@param callback fun(ok: boolean, err: table|nil)
function OmnigentHandler:ensure_session_async(opts, callback)
  opts = opts or {}
  local chat = self.chat
  if not chat.omnigent_session then
    chat.omnigent_session = Session.new({ adapter = chat.adapter, callbacks = {} })
  end
  local session = chat.omnigent_session

  if opts.foreground ~= false then
    self._on_update = function(u)
      self:on_update(u)
    end
    self._on_error = function(e)
      self:on_error(e)
    end
    self._on_stream_end = function(code)
      self:on_stream_end(code)
    end
    session.callbacks.on_update = self._on_update
    session.callbacks.on_error = self._on_error
    session.callbacks.on_stream_end = self._on_stream_end
    session.callbacks.on_lifecycle = function(update, current_session)
      utils.fire("OmnigentLifecycle", {
        bufnr = chat.bufnr,
        session_id = current_session.session_id,
        kind = update.kind,
        response_id = update.response_id,
        active_response_id = current_session.reducer.current_response_id,
        status = current_session.status,
        pending_elicitations = vim.tbl_count(current_session.pending_elicitations or {}),
        error = update.error,
      })
    end
  end

  if session.session_id then
    self:_ensure_observer()
    return callback(true)
  end

  local function ready()
    chat.omnigent_session_id = session.session_id
    if chat.update_metadata then
      pcall(function()
        chat:update_metadata()
      end)
    end
    self:_ensure_observer()
    utils.fire("ChatRefreshCache", { bufnr = chat.bufnr })
    utils.fire("OmnigentSessionReady", { bufnr = chat.bufnr, session_id = session.session_id })
    callback(true)
  end

  if chat.omnigent_session_id then
    session:load_async(chat.omnigent_session_id, function(r, err)
      if not r then
        return callback(false, err)
      end
      self:_hydrate(r.items)
      ready()
    end)
  else
    session:create_async(nil, function(sess, err)
      if not sess then
        return callback(false, err)
      end
      ready()
    end)
  end
end

---Install the persistent background observer and open the stream passively, so
---background/wakeup turns render while the chat is idle. No-op unless the adapter
---opts in via `opts.background_updates` (M4). The stream is idempotent, so a later
---foreground submit reuses it.
function OmnigentHandler:_ensure_observer()
  local chat = self.chat
  local session = chat.omnigent_session
  if not session then
    return
  end
  local opts = session.adapter and session.adapter.opts
  if not (opts and opts.background_updates) then
    return
  end
  if not chat.omnigent_observer then
    local Observer = require("codecompanion.interactions.chat.omnigent.observer")
    chat.omnigent_observer = Observer.new(chat)
  end
  session:set_observer(chat.omnigent_observer)
  session:start_stream()
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
      local line_number = self.chat:add_buf_message({ role = m.role, content = m.content }, { type = mtype })
      if m.tool_call then
        utils.fire("OmnigentToolCall", {
          bufnr = self.chat.bufnr,
          item = m.tool_call,
          line_number = line_number,
        })
        if m.tool_output then
          utils.fire("OmnigentToolOutput", {
            bufnr = self.chat.bufnr,
            call_id = m.tool_call.call_id,
            output = m.tool_output,
          })
        end
      end
    end
  end
  return #msgs
end

---Resume a saved session: load + hydrate history WITHOUT posting a turn. This is
---the correct entry for opening a session to view/continue (used by the M3 resume
---command); submit() is only for posting a new turn.
---@param callback? fun(ok: boolean, err: table|nil)
function OmnigentHandler:resume(callback)
  self:ensure_session_async(nil, function(ok, err)
    self:_detach() -- no active foreground request while merely attached
    if not ok then
      self.chat.status = "error"
      self:_render_error(err or "Failed to resume omnigent session")
    end
    if self.chat.ready_for_input then
      self.chat:ready_for_input()
    end
    if callback then
      callback(ok, err)
    end
  end)
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

---Rewrite a LEADING agent-command escape (`\cmd`) into the slash command the
---harness itself understands (`/cmd`).
---
---CLI-backed harnesses intercept slash commands out of the input stream, but
---CodeCompanion claims the `/` namespace first: a `/help` or `/mcp` typed in a
---chat runs CodeCompanion's version and never reaches the agent, and `/compact`
---only reaches it today because the builtin happens to be gated to HTTP adapters.
---The `\` prefix is the deliberate "this one is for the agent" signal, mirroring
---the ACP path (ACPHandler:transform_acp_commands) so the habit transfers.
---
---Only a LEADING token is rewritten. ACP can replace commands anywhere because it
---has the agent's advertised command list to match against; omnigent advertises
---none, so a positional rule is the only safe one. A doubled prefix (`\\cmd`)
---escapes to a literal `\cmd` for the rare case of genuinely sending one.
---@param text string
---@param trigger? string
---@return string
function OmnigentHandler.transform_agent_command(text, trigger)
  if type(text) ~= "string" or text == "" then
    return text
  end
  trigger = trigger or "\\"
  local esc = vim.pesc(trigger)
  local doubled = text:match("^%s*" .. esc .. esc .. "([%w][-%w]*)")
  if doubled then
    return (text:gsub("^(%s*)" .. esc .. esc, "%1" .. trigger, 1))
  end
  if text:match("^%s*" .. esc .. "[%w][-%w]*") then
    return (text:gsub("^(%s*)" .. esc, "%1/", 1))
  end
  return text
end

---The configured agent-command trigger, shared with the ACP path.
---@return string
local function agent_command_trigger()
  local opts = config.interactions
    and config.interactions.chat
    and config.interactions.chat.slash_commands
    and config.interactions.chat.slash_commands.opts
  return (opts and opts.acp and opts.acp.trigger) or "\\"
end

---@param marked table[]
function OmnigentHandler:_mark_sent(marked)
  for _, m in ipairs(marked) do
    m._meta = m._meta or {}
    m._meta.sent = true
  end
end

---Mark this submit finished and release `chat.current_request` if it still points
---at THIS handle.
---
---Also the reason submit() can return nil: when everything resolves synchronously
---(an inline transport, or a precondition failure) the release happens BEFORE the
---caller's `chat.current_request = submit()` assignment, which would otherwise
---resurrect a dead handle and wedge the buffer.
function OmnigentHandler:_settle()
  self._settled = true
  if self._handle and self.chat.current_request == self._handle then
    self.chat.current_request = nil
  end
end

---Submit a foreground turn.
---
---Returns its handle IMMEDIATELY, before the session exists. Everything from here
---on -- resolving targets, creating or loading the session, posting the message --
---is asynchronous, because each of those is a REST round trip and blocking on them
---is the editor freezing the moment you press send.
---
---The handle is what keeps a second submit out while that is in flight
---(`Chat:submit` early-returns while `chat.current_request` is set), so every exit
---path must release it: `_complete` -> `chat:done()` for a started turn, `_settle`
---for the paths that never start one.
---@param payload table
---@return table|nil request handle
function OmnigentHandler:submit(payload)
  local chat = self.chat

  local handle = {
    -- Filled in once the session resolves; nil until then.
    session_id = nil,
    status = function()
      local s = chat.omnigent_session
      return s and s.status
    end,
    cancel = function()
      self._cancelled = true
      if self._post then
        pcall(function()
          self._post.stop()
        end)
      end
      -- Cancelling before the session exists cannot interrupt anything: the
      -- create/load may still land server-side, but it lands as an idle session
      -- nobody posted to, and `_cancelled` keeps this handler off it.
      local s = chat.omnigent_session
      if s and s.session_id then
        pcall(function()
          s:interrupt_async()
        end)
      end
    end,
  }
  self._handle = handle

  self:ensure_session_async(nil, function(ok, err)
    if self._cancelled then
      return
    end
    if not ok then
      -- No turn was started; surface the error and free the buffer for a retry.
      chat.status = "error"
      self:_render_error(err or "Failed to establish omnigent session")
      self:_detach()
      self:_settle()
      chat:done(self.output)
      return
    end

    local session = chat.omnigent_session
    handle.session_id = session.session_id

    local text, marked = self:_unsent_user_text()
    if not text or text == "" then
      -- Not an error. This is a bare resume (history hydrated, no new prompt) or a
      -- blank submit: don't post, don't mark the chat failed -- detach and hand
      -- control back to the user.
      log:debug("[Omnigent::Handler] Nothing to submit; ready for input")
      self:_detach()
      self:_settle()
      if chat.ready_for_input then
        chat:ready_for_input()
      end
      return
    end

    -- Announce the request lifecycle BEFORE opening the stream / posting, so a fast
    -- terminal event delivered on the stream can never reach _complete() before
    -- request_id exists (which would drop RequestFinished and desync the queue).
    self.request_id = tostring(math.random(10000000))
    utils.fire("RequestStarted", {
      id = self.request_id,
      bufnr = chat.bufnr,
      adapter = {
        name = chat.adapter.name,
        formatted_name = chat.adapter.formatted_name,
        type = "omnigent",
      },
    })

    -- Open the stream BEFORE posting: it is live-tail, not a replay source.
    session:start_stream()

    -- Rewrite on the WIRE only: the transcript keeps what the user actually typed,
    -- matching how the ACP path transforms its payload rather than its history.
    -- _mark_sent stays on the success path, so a failure leaves the text unsent
    -- and a retry resends it exactly once.
    local wire = OmnigentHandler.transform_agent_command(text, agent_command_trigger())
    -- The chat buffer already shows this as `## Me`. A native harness mirrors
    -- typed input back as a user output item, so suppress that echo (both forms:
    -- the mirror carries what the agent received, not what was typed).
    render.note_local_user_echo(chat, text, wire)

    self._post = session:post_message_async(wire, function(res, perr)
      if not res then
        self:_render_error(perr or "Failed to post message")
        self:_complete("error") -- fires RequestFinished + chat:done + detaches
        return
      end
      self:_mark_sent(marked)
    end)
  end)

  if self._settled then
    return nil
  end
  return handle
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
  elseif k == "tool_output_delta" then
    self.chat:add_buf_message({ role = C.LLM_ROLE, content = u.delta }, { type = MT.TOOL_MESSAGE })
    utils.fire("OmnigentToolOutput", {
      bufnr = self.chat.bufnr,
      call_id = u.call_id,
      delta = u.delta,
      streaming = true,
    })
  elseif k == "elicitation" then
    -- The turn is blocked server-side until this resolves; present it and resolve
    -- via the session. We are the approval authority (never auto-approve).
    require("codecompanion.interactions.chat.omnigent.elicitation").handle(self.chat, self.chat.omnigent_session, u)
  elseif k == "elicitation_resolved" then
    self.chat:add_buf_message(
      { role = C.LLM_ROLE, content = "\n> ✓ approval resolved\n" },
      { type = MT.SYSTEM_MESSAGE or MT.LLM_MESSAGE }
    )
  elseif k == "item_committed" then
    self:_render_item(u)
  elseif k == "child_session" or k == "child_session_created" then
    self.chat:add_buf_message(
      { role = C.LLM_ROLE, content = render.child_session_line(u) },
      { type = MT.SYSTEM_MESSAGE or MT.LLM_MESSAGE }
    )
  elseif k == "policy_denied" then
    self.chat:add_buf_message(
      { role = C.LLM_ROLE, content = render.policy_denied_line(u) },
      { type = MT.SYSTEM_MESSAGE or MT.LLM_MESSAGE }
    )
  elseif require("codecompanion.interactions.chat.omnigent.compaction").owns(k) then
    -- A harness can compact itself mid-turn on context overflow. This is NOT a
    -- turn boundary: render the marker and keep streaming.
    require("codecompanion.interactions.chat.omnigent.compaction").handle_update(self.chat, u)
  elseif k == "turn_completed" then
    self:_fire_usage(u.usage) -- response.completed.usage carries context_tokens
    self:_complete("success")
  elseif k == "turn_failed" or k == "error" then
    self:_render_error(u.error or "omnigent turn failed")
    self:_complete("error")
  elseif k == "interrupted" or k == "turn_cancelled" then
    self:_complete("cancelled")
  elseif k == "status" and u.status == "failed" then
    -- A session-level failure (e.g. runner_disconnected) arrives as a status
    -- update, not turn_failed. Surface it instead of leaving the turn silent.
    self:_render_error(u.error or "omnigent session failed")
    self:_complete("error")
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
  -- child_session / other: surfaced in M5.
end

---Fire a transport-neutral usage event so external consumers (winbar stats,
---context-%) can update without reaching into omnigent internals.
---@param usage any
function OmnigentHandler:_fire_usage(usage)
  utils.fire("OmnigentUsage", {
    bufnr = self.chat.bufnr,
    session_id = self.chat.omnigent_session_id,
    usage = render.enrich_usage(usage, self.chat.omnigent_session),
  })
end

---Render a committed durable item during a live turn. Assistant message text is
---already streamed via deltas, so only tool calls get a compact marker here.
---@param u CodeCompanion.Omnigent.Update
function OmnigentHandler:_render_item(u)
  local MT = self.chat.MESSAGE_TYPES
  if u.duplicate then
    -- Second arrival of a tool call / result that already rendered. See
    -- Reducer:_dedupe_tool_item -- omnigent emits both by design and expects the
    -- client to keep the first.
    return
  end
  if u.item_type == "function_call" then
    -- Surface the committed tool call for external consumers (diff tracking, task
    -- attribution): `item.arguments` (a JSON string of the tool params) is the
    -- only place a server-side tool's file paths appear.
    local item = u.item or { name = u.tool_name }
    local line_number = self.chat:add_buf_message(
      { role = config.constants.LLM_ROLE, content = render.tool_call_line(u.item or { name = u.tool_name }) },
      { type = MT.SYSTEM_MESSAGE or MT.LLM_MESSAGE }
    )
    utils.fire("OmnigentToolCall", { bufnr = self.chat.bufnr, item = item, line_number = line_number })
  elseif u.item_type == "function_call_output" then
    local item = u.item or {}
    utils.fire("OmnigentToolOutput", {
      bufnr = self.chat.bufnr,
      call_id = u.call_id or item.call_id,
      output = item.output,
    })
  elseif
    u.item_type == "message"
    and u.role == "user"
    and type(u.text) == "string"
    and u.text ~= ""
    and not render.consume_local_user_echo(self.chat, u.text)
  then
    -- A user message committed *during* our turn: someone steered. That is this
    -- client posting mid-turn, another client posting into the same session, or
    -- omnigent's own inbox plumbing.
    --
    -- The observer renders these for background turns; without the same branch
    -- here they were silently dropped whenever a foreground turn owned the
    -- stream, which is the common case (the handler is bound for the whole turn
    -- it started). Deliberately NOT appended to `self.output`: that accumulates
    -- the assistant text handed to chat:done().
    if render.is_system_injected(u.text) then
      self.chat:add_buf_message(
        { role = config.constants.LLM_ROLE, content = render.system_injection_note(u.text) },
        { type = MT.SYSTEM_MESSAGE or MT.LLM_MESSAGE }
      )
    else
      self.chat:add_buf_message(
        { role = config.constants.USER_ROLE, content = u.text },
        { type = MT.USER_MESSAGE, force_role = true }
      )
      if self.chat.add_message then
        self.chat:add_message({ role = config.constants.USER_ROLE, content = u.text }, { _meta = { sent = true } })
      end
      -- Resuming assistant deltas get their own `## <LLM>` header for free:
      -- Builder:_should_add_header fires on a role change. Coming IN needs
      -- force_role though -- a steer lands while the last role is still `user`
      -- (our own submit), and a role change is the only other thing that emits
      -- a header, so it would otherwise be appended to that message.
    end
  elseif
    u.item_type == "message"
    and u.role == "assistant"
    and not u.text_streamed
    and type(u.text) == "string"
    and u.text ~= ""
  then
    table.insert(self.output, u.text)
    self.chat:add_buf_message({ role = config.constants.LLM_ROLE, content = u.text }, { type = MT.LLM_MESSAGE })
  end
  -- Function-call output and resource events are folded or setup-only.
end

---Post `text` into the turn that is already running, instead of starting a new one.
---
---Omnigent has no steer flag on the wire: POSTing a message while a task is active
---IS steering (the server's create-or-steer path hands it to the active task's
---inbox, and for an SDK harness the runner live-injects it into the streaming
---response). So steering is only a question of posting now rather than waiting.
---
---This cannot go through `Chat:submit`, which early-returns while
---`chat.current_request` is set -- that guard is exactly what makes a *second
---turn* impossible, and steering is not a second turn.
---
---The transcript is written here rather than left to the round-trip, because a
---steered message comes back as `session.input.consumed` (see omnigent's
---SessionInputConsumedEvent: emitted "either onto a steered active turn or as the
---seed item of a freshly-started one") -- an event that carries no response id and
---that nothing renders. `item_committed` is response OUTPUT only, so waiting for
---it would leave a steer invisible on every non-native harness.
---@param chat table
---@param text string
---@param on_result? fun(ok: boolean, err?: string) Fires when the POST settles
---@return boolean accepted, string? err
function OmnigentHandler.steer(chat, text, on_result)
  local session = chat and chat.omnigent_session
  if not (session and session.post_message_async) then
    return false, "no omnigent session on this chat"
  end
  -- No durable session yet means there is no turn to steer into; posting would
  -- build a request against a nil id.
  if not session.session_id then
    return false, "no active omnigent session to steer"
  end
  if type(text) ~= "string" or vim.trim(text) == "" then
    return false, "nothing to steer"
  end

  local C = config.constants
  local MT = chat.MESSAGE_TYPES
  local wire = OmnigentHandler.transform_agent_command(text, agent_command_trigger())

  local function post(reason)
    -- force_role because the line above this is almost always the user's own
    -- submit, and `Builder:_should_add_header` only emits a header on a role
    -- CHANGE -- so without it a steer is written into that same `## Me` block
    -- and reads as an edit of the previous message rather than a new one.
    chat:add_buf_message({ role = C.USER_ROLE, content = text }, { type = MT.USER_MESSAGE, force_role = true })
    if chat.add_message then
      chat:add_message({ role = C.USER_ROLE, content = text }, { _meta = { sent = true } })
    end
    render.note_local_user_echo(chat, text, wire)

    if reason == "timeout" or reason == "turn_ended" then
      log:warn("[Omnigent::Handler] posting a steer with no live turn to fold it into (%s)", reason)
    end

    session:post_message_async(wire, function(res, perr)
      if res then
        return on_result and on_result(true)
      end
      local msg = type(perr) == "table" and (perr.message or vim.inspect(perr)) or tostring(perr)
      log:error("[Omnigent::Handler] steer failed: %s", msg)
      chat:add_buf_message(
        { role = C.LLM_ROLE, content = "\n> [!WARNING] Steer failed: " .. msg .. "\n" },
        { type = MT.SYSTEM_MESSAGE or MT.LLM_MESSAGE }
      )
      if on_result then
        on_result(false, msg)
      end
    end)
  end

  -- Hold until a POST would actually be forwarded into the running turn (see
  -- `Session:steerable_now`). Sending in the gap between "turn started" and
  -- "response streaming" is the whole bug: the runner buffers it and the agent
  -- takes it as a follow-up turn instead of folding it into what it is doing.
  --
  -- Renders at post time, not now, so a message in the transcript always means
  -- the agent received it.
  session:when_steerable(post)
  return true
end

---@param err table|string
function OmnigentHandler:on_error(err)
  self:_render_error(err)
  self:_complete("error")
end

---The stream ended. Only meaningful while a foreground turn is in flight: if it
---drops before a terminal event, finish with an error so the input queue isn't
---wedged. After completion this is a no-op (guarded by _done). Background-mode
---reconnect is handled inside the session, not here.
---@param code? number
function OmnigentHandler:on_stream_end(code)
  if self._done or not self.request_id then
    return
  end
  self:_render_error("omnigent stream ended before the turn completed")
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
    if s.callbacks.on_stream_end == self._on_stream_end then
      s.callbacks.on_stream_end = nil
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
  self:_settle()
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
