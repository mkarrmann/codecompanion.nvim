--=============================================================================
-- Omnigent context compaction
--
-- Compaction is a SERVER-SIDE operation on the durable session, not a client-side
-- re-summarisation of the chat buffer (which is what
-- interactions/chat/context_management/compaction.lua does for HTTP adapters).
-- The editor asks for it and then watches; it never rewrites history itself.
--
-- Two server paths hide behind one request, and they differ in timing:
--   * runner-backed (*-native agents): `/compact` is injected into the agent's
--     terminal and the POST answers immediately. The work happens afterwards, and
--     the completion event carries no token count (usage arrives separately as
--     `external_session_usage`).
--   * server-side (SDK harnesses): the server summarises inline and answers only
--     once finished -- which can take longer than a normal REST budget.
-- So the HTTP response is treated as "accepted" only, and the TERMINAL SIGNAL is
-- always the `response.compaction.completed` / `.failed` SSE event. That also
-- covers the third case the client never initiates: a harness compacting itself
-- on context overflow, which arrives as the same pair of events out of nowhere.
--
-- Two server-side behaviours to know about, both observed against 0.6.0:
--   * The server refuses server-side compaction outright (HTTP 400) when the
--     agent spec declares no summarisation model -- true of every stock SDK agent
--     (claude-sdk, codex, ...). Compaction there is a native-agent feature in
--     practice, and the refusal is a normal answer, not an error to dramatise.
--   * A terminal-backed agent that DECLINES the injected `/compact` (e.g. Claude
--     Code refusing a too-short conversation) emits `in_progress` and then
--     nothing at all -- no `failed`. The watchdog exists for exactly that hole.
--
-- What the user sees:
--   request  -> an animated "Compacting context…" indicator pinned below the
--               transcript (the operation is long and silent; a static label
--               would be indistinguishable from a hang)
--   completed-> indicator cleared, a permanent boundary marker appended, and the
--               context meter dropped to the reported post-compaction size
--   failed   -> indicator cleared, error notified, NO marker (history is intact)
--   timeout  -> indicator cleared with a warning; a late terminal event still
--               renders normally, since rendering never depends on the in-flight
--               request state
--=============================================================================

local config = require("codecompanion.config")
local log = require("codecompanion.utils.log")
local render = require("codecompanion.interactions.chat.omnigent.render")
local utils = require("codecompanion.utils")

local M = {}

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPINNER_INTERVAL = 80

-- Bounds both the HTTP budget and (slightly extended) the watchdog. Long enough
-- to summarise a large transcript, short enough that a harness which silently
-- declined does not strand the indicator. Raise via the adapter's
-- `opts.compaction_timeout` if a server-side summarisation legitimately runs
-- longer than this.
local DEFAULT_TIMEOUT = 180000

local NS = vim.api.nvim_create_namespace("codecompanion_omnigent_compaction")

---@param chat CodeCompanion.Chat
---@return number
local function timeout_for(chat)
  local opts = (chat.adapter and chat.adapter.opts) or {}
  return tonumber(opts.compaction_timeout) or DEFAULT_TIMEOUT
end

---Start the animated indicator. Repaints from scratch each tick so it survives
---buffer writes underneath it, and always sits on the last line.
---@param bufnr number
---@return fun() stop
local function start_indicator(bufnr)
  local timer = vim.uv.new_timer()
  local frame = 0
  local stopped = false

  timer:start(0, SPINNER_INTERVAL, function()
    vim.schedule(function()
      if stopped or not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
      local last = vim.api.nvim_buf_line_count(bufnr) - 1
      pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, last, 0, {
        virt_text = { { SPINNER_FRAMES[frame + 1] .. " Compacting context…", "Comment" } },
        virt_text_pos = "eol",
      })
      frame = (frame + 1) % #SPINNER_FRAMES
    end)
  end)

  return function()
    stopped = true
    pcall(function()
      timer:stop()
    end)
    pcall(function()
      timer:close()
    end)
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
    end
  end
end

---@param chat CodeCompanion.Chat
---@param phase string requested|started|completed|failed|timeout
---@param data? table
local function fire(chat, phase, data)
  utils.fire(
    "OmnigentCompaction",
    vim.tbl_extend("force", {
      bufnr = chat.bufnr,
      id = chat.id,
      session_id = chat.omnigent_session_id,
      phase = phase,
    }, data or {})
  )
end

---Tear down the in-flight request state (indicator + watchdog). Idempotent.
---@param chat CodeCompanion.Chat
local function clear_inflight(chat)
  local state = chat._omnigent_compaction
  if not state then
    return
  end
  chat._omnigent_compaction = nil
  if state.stop_indicator then
    pcall(state.stop_indicator)
  end
  if state.watchdog then
    pcall(function()
      state.watchdog:stop()
    end)
    pcall(function()
      state.watchdog:close()
    end)
  end
end

---True if this chat is waiting on a compaction it requested.
---@param chat CodeCompanion.Chat
---@return boolean
function M.in_flight(chat)
  return chat._omnigent_compaction ~= nil
end

---Abandon any in-flight compaction UI (chat closing / adapter swap). The server
---side is unaffected -- compaction is not cancellable once dispatched.
---@param chat CodeCompanion.Chat
function M.cancel(chat)
  clear_inflight(chat)
end

---Begin (or adopt) the progress indicator. Called both by an explicit request and
---by a `compaction_started` event we did not initiate, so harness-driven
---auto-compaction gets the same visible treatment.
---@param chat CodeCompanion.Chat
---@return table|nil state The in-flight record, or nil if one was already running
local function begin_indicator(chat)
  if chat._omnigent_compaction then
    return nil
  end
  if not (chat.bufnr and vim.api.nvim_buf_is_valid(chat.bufnr)) then
    return nil
  end

  local state = { stop_indicator = start_indicator(chat.bufnr) }
  chat._omnigent_compaction = state

  -- Deliberately longer than the HTTP budget so a timed-out POST reports its own
  -- (more specific) error first; this only catches the case where NO signal at
  -- all comes back -- e.g. a runner that acked the control and then went quiet.
  local timeout = timeout_for(chat) + 15000
  state.watchdog = vim.uv.new_timer()
  state.watchdog:start(timeout, 0, function()
    vim.schedule(function()
      -- Only fire if THIS request is still the in-flight one.
      if chat._omnigent_compaction ~= state then
        return
      end
      clear_inflight(chat)
      fire(chat, "timeout", { timeout = timeout })
      utils.notify(
        string.format(
          "Omnigent compaction did not report back within %ds. It may still be running, or a "
            .. "terminal-backed agent declined it (those report nothing when they refuse).",
          math.floor(timeout / 1000)
        ),
        vim.log.levels.WARN
      )
    end)
  end)

  return state
end

-- Ordered compaction strategies. Both are real, and which one a session supports
-- depends on its harness, so the default tries them in order rather than making
-- the caller know:
--
--   control_event  POST a `compact` control. The server dispatches by harness:
--                  terminal-backed agents get `/compact` injected into their pane;
--                  otherwise it summarises server-side. Reports progress properly
--                  over SSE, so this is preferred WHERE IT WORKS -- but the server
--                  refuses (HTTP 4xx) for any harness that declares no
--                  summarisation model, which is every stock SDK agent.
--   slash_command  Post the agent's own `/compact` as an ordinary user message and
--                  let the CLI intercept it. This is the only compaction available
--                  to an SDK harness, and it is INVISIBLE: no compaction events, no
--                  durable item (verified -- omnigent's PreCompact detection never
--                  fires on this path). The turn ending is the only completion
--                  signal, so the marker records a request, not a confirmation.
--
-- Override per-adapter with `opts.compaction_strategies`, e.g. to pin one path if
-- a future server version changes which of them works.
local DEFAULT_STRATEGIES = { "control_event", "slash_command" }

---@param chat CodeCompanion.Chat
---@return string[]
local function strategies_for(chat)
  local opts = (chat.adapter and chat.adapter.opts) or {}
  local s = opts.compaction_strategies
  if type(s) == "table" and #s > 0 then
    return s
  end
  return DEFAULT_STRATEGIES
end

---Post the agent's own slash command and wait for the turn to end.
---@param chat CodeCompanion.Chat
---@param state table
---@return boolean ok, table|nil err
local function run_slash_command(chat, state)
  local ok, err = chat.omnigent_session:compact_via_slash()
  if not ok then
    return false, err
  end
  state.strategy = "slash_command"
  fire(chat, "requested", { strategy = "slash_command" })
  return true
end

---Post the server control, falling through to the next strategy on a refusal.
---@param chat CodeCompanion.Chat
---@param state table
---@param on_refused fun()
---@return boolean ok, table|nil err
local function run_control_event(chat, state, on_refused)
  state.strategy = "control_event"
  local accepted, err = chat.omnigent_session:compact({ timeout = timeout_for(chat) }, function(ok, post_err)
    if ok then
      -- Accepted. The terminal SSE event decides the outcome -- for the
      -- server-side path it has almost certainly already arrived.
      return
    end
    -- Stale: the watchdog gave up, or the chat moved on. Don't re-report.
    if chat._omnigent_compaction ~= state then
      return
    end
    -- A refusal is terminal for THIS strategy: nothing started, so no SSE will
    -- follow. Fall through rather than surfacing it -- "this harness has no
    -- server-side compaction" is a routing fact, not a user-facing failure.
    local status = type(post_err) == "table" and post_err.status
    if status and status >= 400 and status < 500 then
      log:debug("[Omnigent::Compaction] control_event refused (%s); trying the next strategy", tostring(status))
      return on_refused()
    end
    clear_inflight(chat)
    fire(chat, "failed", { error = post_err, strategy = "control_event" })
    M.render_failure(chat, post_err, { transcript = false })
  end)
  if not accepted then
    return false, err
  end
  fire(chat, "requested", { strategy = "control_event" })
  return true
end

---Request compaction of the chat's durable session.
---
---Refuses (without side effects) when there is nothing to compact, a turn is in
---flight, or a compaction is already pending -- the server would reject the first
---two anyway, but a local check gives an immediate, specific message.
---@param chat CodeCompanion.Chat
---@return boolean ok, table|nil err
function M.request(chat)
  local session = chat.omnigent_session
  if not session or not session.session_id then
    return false, { message = "this chat has no durable Omnigent session yet -- send a turn first" }
  end
  if chat.current_request then
    return false, { message = "wait for the current request to finish before compacting" }
  end
  if session:busy() then
    return false, { message = "cannot compact while a turn is running; cancel or wait for it to finish" }
  end
  if M.in_flight(chat) then
    return false, { message = "a compaction is already in progress for this chat" }
  end

  local state = begin_indicator(chat)
  if not state then
    return false, { message = "chat buffer is no longer valid" }
  end

  local queue = vim.deepcopy(strategies_for(chat))
  local last_err
  local advance

  advance = function()
    while #queue > 0 do
      local name = table.remove(queue, 1)
      local ok, err
      if name == "control_event" then
        ok, err = run_control_event(chat, state, function()
          -- Asynchronous refusal: resume the queue from the callback.
          if not advance() then
            clear_inflight(chat)
            fire(chat, "failed", { error = last_err })
            M.render_failure(chat, last_err, { transcript = false })
          end
        end)
      elseif name == "slash_command" then
        ok, err = run_slash_command(chat, state)
      else
        log:warn("[Omnigent::Compaction] unknown strategy %q", tostring(name))
      end
      if ok then
        return true
      end
      last_err = err or last_err
    end
    return false
  end

  if not advance() then
    clear_inflight(chat)
    return false, last_err or { message = "no compaction strategy succeeded" }
  end
  return true
end

---A turn finished. Only meaningful for the slash_command strategy, whose
---compaction the server never reports: the CLI swallows the command, emits no
---assistant text and no compaction event, so the end of the turn it created is
---the only signal we get.
---@param chat CodeCompanion.Chat
function M.note_turn_end(chat)
  local state = chat._omnigent_compaction
  if not state or state.strategy ~= "slash_command" then
    return
  end
  clear_inflight(chat)
  pcall(function()
    chat:add_buf_message({
      role = config.constants.LLM_ROLE,
      content = "\n> [!NOTE] Compaction requested (`/compact`)\n"
        .. "> Handled inside the agent's own CLI, which reports nothing back — the\n"
        .. "> context meter above may lag until the next turn.\n",
    }, { type = chat.MESSAGE_TYPES.SYSTEM_MESSAGE or chat.MESSAGE_TYPES.LLM_MESSAGE })
  end)
  fire(chat, "completed", { strategy = "slash_command", observed = false })
  utils.notify("Omnigent: /compact sent to the agent.", vim.log.levels.INFO)
end

---Report a failure. History is untouched either way, so this never writes a
---boundary marker.
---
---`opts.transcript` controls whether a note is also left in the buffer. It is on
---only for a failure the SERVER reported mid-flight: that can land while the user
---is away from the chat, and the reason the context did not shrink is worth
---keeping. A synchronous rejection is a toast only -- nothing was attempted, and a
---permanent entry for "this harness can't do that" is pure clutter.
---@param chat CodeCompanion.Chat
---@param err? table
---@param opts? table { transcript?: boolean }
function M.render_failure(chat, err, opts)
  opts = opts or {}
  local msg = (type(err) == "table" and err.message) or (err ~= nil and tostring(err)) or "unknown error"
  utils.notify("Omnigent compaction failed: " .. msg, vim.log.levels.ERROR)
  if opts.transcript == false then
    return
  end
  local MT = chat.MESSAGE_TYPES
  pcall(function()
    chat:add_buf_message({
      role = config.constants.LLM_ROLE,
      content = "\n> [!WARNING] Compaction failed: " .. msg .. "\n> Conversation history is unchanged.\n",
    }, { type = MT.SYSTEM_MESSAGE or MT.LLM_MESSAGE })
  end)
end

---Handle a compaction lifecycle update from the stream. Shared by the foreground
---handler and the background observer so an explicitly requested compaction, a
---background one and a harness-driven one all render identically.
---
---Rendering never consults the in-flight state: a late event (after the watchdog
---gave up) or one nobody asked for still produces the correct transcript.
---@param chat CodeCompanion.Chat
---@param u CodeCompanion.Omnigent.Update
function M.handle_update(chat, u)
  local k = u.kind
  local MT = chat.MESSAGE_TYPES

  if k == "compaction_started" then
    begin_indicator(chat)
    fire(chat, "started", { task_id = u.task_id })
    return
  end

  if k == "compaction_failed" then
    clear_inflight(chat)
    fire(chat, "failed", { task_id = u.task_id })
    M.render_failure(chat, { message = "the server reported a compaction failure" })
    return
  end

  if k ~= "compaction_completed" then
    return
  end

  clear_inflight(chat)

  -- The stream replays in-flight state on reconnect, so the same completion can
  -- arrive twice. Suppress the duplicate marker rather than stacking boundaries.
  if u.task_id and chat._omnigent_compaction_done == u.task_id then
    log:debug("[Omnigent::Compaction] ignoring replayed completion %s", tostring(u.task_id))
    return
  end
  chat._omnigent_compaction_done = u.task_id

  pcall(function()
    chat:add_buf_message({
      role = config.constants.LLM_ROLE,
      content = render.compaction_marker(u),
    }, { type = MT.SYSTEM_MESSAGE or MT.LLM_MESSAGE })
  end)

  -- Drop the context meter now rather than leaving the pre-compaction figure up
  -- until the next turn reports usage.
  if u.usage then
    utils.fire("OmnigentUsage", {
      bufnr = chat.bufnr,
      session_id = chat.omnigent_session_id,
      usage = render.enrich_usage(u.usage, chat.omnigent_session),
    })
  end
  if chat.update_metadata then
    pcall(function()
      chat:update_metadata()
    end)
  end

  fire(chat, "completed", { task_id = u.task_id, total_tokens = u.total_tokens })
  utils.notify("Omnigent context compacted.", vim.log.levels.INFO)
end

---Whether this update kind belongs to the compaction lifecycle.
---@param kind string
---@return boolean
function M.owns(kind)
  return kind == "compaction_started" or kind == "compaction_completed" or kind == "compaction_failed"
end

return M
