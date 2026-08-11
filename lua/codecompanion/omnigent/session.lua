--=============================================================================
-- Omnigent session runtime
--
-- The stateful, per-chat object that owns a single omnigent conversation -- the
-- conceptual equivalent of acp.Connection, but for REST + SSE. It resolves
-- targets (agent / host / workspace), creates or loads the durable session,
-- holds the live SSE subscription, feeds events through the reducer, and exposes
-- foreground actions (post message, interrupt, patch model). It never touches a
-- buffer: it emits normalised updates to `callbacks.on_update` and the chat
-- render layer decides what to draw.
--
-- Host/workspace binding is FAIL-CLOSED (see client.resolve_host): rather than
-- silently sending host_id=nil (which the server runs locally, skipping
-- workspace validation), an unresolved "auto" host refuses. workspace="auto"
-- only sends the local cwd when the resolved host IS this machine.
--=============================================================================

local Client = require("codecompanion.omnigent.client")
local Events = require("codecompanion.omnigent.events")
local log = require("codecompanion.utils.log")

---@class CodeCompanion.Omnigent.Session
---@field client CodeCompanion.Omnigent.Client
---@field adapter CodeCompanion.OmnigentAdapter
---@field session_id? string
---@field agent_id? string
---@field agent_name? string
---@field harness? string
---@field labels? table
---@field host_id? string
---@field workspace? string
---@field status? string
---@field model? string
---@field model_override? string
---@field reasoning_effort? string
---@field model_options? table
---@field context_window? integer Context window (tokens) of the active model, from the session snapshot
---@field usage_by_model? table Per-model token/cost breakdown, from the session snapshot
---@field title? string
---@field codex_goal? table
---@field reducer CodeCompanion.Omnigent.Reducer
---@field callbacks table { on_update?, on_error?, on_stream_end?, on_lifecycle? }
---@field _stream? table
local Session = {}
Session.__index = Session

local lifecycle_kinds = {
  turn_started = true,
  elicitation = true,
  elicitation_resolved = true,
  turn_completed = true,
  turn_failed = true,
  turn_cancelled = true,
  interrupted = true,
  error = true,
  status = true,
  stream_error = true,
  compaction_started = true,
  compaction_completed = true,
  compaction_failed = true,
}

---Lowercased leading DNS label.
---@param name string
---@return string
local function leading_label(name)
  return (tostring(name):lower():gsub("%..*$", ""))
end

---Is `host` this machine?
---@param host table
---@param fqdn string
---@return boolean
local function is_local(host, fqdn)
  if not host then
    return false
  end
  return host.name == fqdn or leading_label(host.name or "") == leading_label(fqdn or "")
end

---@param hosts table[]
---@param id string
---@return table|nil
local function find_host(hosts, id)
  for _, h in ipairs(hosts) do
    if h.host_id == id then
      return h
    end
  end
  return nil
end

---@param opts table { adapter, client?, callbacks?, request?, job? }
---@return CodeCompanion.Omnigent.Session
function Session.new(opts)
  opts = opts or {}
  local adapter = opts.adapter
  local client = opts.client
    or Client.new({
      url = adapter and adapter.url,
      headers = adapter and adapter.env and adapter.env.headers or nil,
      request = opts.request,
      async_request = opts.async_request,
      job = opts.job,
    })
  return setmetatable({
    client = client,
    adapter = adapter or {},
    reducer = Events.new(),
    callbacks = opts.callbacks or {},
    observer = nil,
    -- "Already materialised in this chat" bookkeeping, consulted by _reconcile.
    -- THREE sets, because the stream and the durable store do not share an id
    -- namespace for every item type:
    --   * seen_items      -- store ids (32-hex). Only messages reach the stream
    --                        carrying their store id; user messages arrive via
    --                        `session.input.consumed`, which does carry it.
    --   * seen_calls      -- call_ids of rendered tool calls. Tool items reach
    --                        the stream with a freshly-minted `fc_<uuid>` id
    --                        that is NOT the store id, so call_id is the only
    --                        stable correlator between stream and store.
    --   * seen_call_outputs -- ditto for `fco_<uuid>` tool results.
    seen_items = {},
    seen_calls = {},
    seen_call_outputs = {},
    _stream = nil,
    _stopping = false,
    _reconnect_scheduled = false,
    -- Injectable deferred scheduler (tests pass a synchronous variant). Signature
    -- mirrors vim.defer_fn(fn, ms).
    _defer = opts.defer or function(fn, ms)
      vim.defer_fn(fn, ms or 0)
    end,
  }, Session)
end

---Attach the persistent background observer (the consumer of updates while no
---foreground request is bound). See interactions/chat/omnigent/observer.lua.
---@param observer table|nil
function Session:set_observer(observer)
  self.observer = observer
end

---Resolve agent / host / workspace for a new session. FAIL-CLOSED.
---@param opts? table { agent?, host?, workspace?, agents?, hosts?, labels? }
---@return table|nil targets { agent_id, host_id?, workspace? }
---@return table|nil err
function Session:resolve_targets(opts)
  opts = opts or {}
  local d = self.adapter.defaults or {}

  local agent_id, err = self.client:resolve_agent(opts.agent or d.agent, { agents = opts.agents })
  if not agent_id then
    return nil, err
  end

  local hosts = opts.hosts
  if not hosts then
    hosts, err = self.client:list_hosts()
    if not hosts then
      return nil, err
    end
  end

  local host_spec = opts.host or d.host or "auto"
  local host_id
  if host_spec == "none" then
    host_id = nil -- explicit opt-in to a host-less (server-local/headless) session
  else
    local herr
    host_id, herr = self.client:resolve_host(host_spec, { hosts = hosts })
    if not host_id then
      return nil, herr
    end
  end

  local workspace = opts.workspace or d.workspace or "auto"
  if workspace == "auto" then
    if host_id then
      local host = find_host(hosts, host_id)
      if host and is_local(host, self.client.hostname) then
        workspace = vim.fn.getcwd()
      else
        return nil, {
          message = "workspace='auto' but host '"
            .. (host and host.name or tostring(host_id))
            .. "' is not this machine; set an explicit workspace",
          code = "workspace_required",
          action = "Configure an explicit workspace path for the remote host.",
        }
      end
    else
      workspace = nil -- headless: no workspace
    end
  end

  return { agent_id = agent_id, host_id = host_id, workspace = workspace }
end

---nil out a JSON-null (vim.NIL) so it can't poison `a or b` chains. Defensive:
---the client/sse decoders already map null->absent, but a snapshot may reach here
---from another path (e.g. a hand-built table or a future decoder change).
---@generic T
---@param v T
---@return T|nil
local function nn(v)
  if v == nil or v == vim.NIL then
    return nil
  end
  return v
end

---Fold a session snapshot (from create/get) into this runtime's state.
---@param s table
function Session:_ingest_snapshot(s)
  if type(s) ~= "table" then
    return
  end
  self.session_id = nn(s.id) or self.session_id
  self.agent_id = nn(s.agent_id) or self.agent_id
  self.agent_name = nn(s.agent_name) or self.agent_name
  self.harness = nn(s.harness) or self.harness
  self.labels = nn(s.labels) or self.labels
  self.host_id = nn(s.host_id) or self.host_id
  self.workspace = nn(s.workspace) or self.workspace
  self.status = nn(s.status) or self.status
  self.model = nn(s.llm_model) or nn(s.model) or self.model
  self.model_override = nn(s.model_override) or self.model_override
  self.reasoning_effort = nn(s.reasoning_effort) or self.reasoning_effort
  self.model_options = nn(s.model_options) or self.model_options
  -- The server reports the active model's context window (and per-model usage)
  -- on the session object; the SSE session.usage event leaves context_window
  -- null, so the snapshot is the authoritative source for the context-% UI.
  self.context_window = nn(s.context_window) or self.context_window
  self.usage_by_model = nn(s.usage_by_model) or self.usage_by_model
  self.title = nn(s.title) or self.title
end

---Whether the server snapshot authorizes Codex Goal operations.
---@return boolean
function Session:supports_codex_goal()
  return type(self.labels) == "table" and self.labels["omnigent.wrapper"] == "codex-native-ui"
end

---Validate that this session can perform Codex Goal operations.
---@param callback function
---@return boolean
function Session:_require_codex_goal(callback)
  if not self.session_id then
    callback(nil, { message = "No active Omnigent session", code = "session_required" })
    return false
  end
  if not self:supports_codex_goal() then
    callback(nil, { message = "Codex Goal requires a codex-native-ui session", code = "goal_unsupported" })
    return false
  end
  return true
end

---@param callback fun(goal: table|nil, err: table|nil)
---@return table|nil
function Session:get_codex_goal(callback)
  if not self:_require_codex_goal(callback) then
    return nil
  end
  return self.client:get_codex_goal(self.session_id, function(goal, err)
    if not err then
      self.codex_goal = goal
    end
    callback(goal, err)
  end)
end

---@param goal table
---@param callback fun(goal: table|nil, err: table|nil)
---@return table|nil
function Session:set_codex_goal(goal, callback)
  if not self:_require_codex_goal(callback) then
    return nil
  end
  return self.client:set_codex_goal(self.session_id, goal, function(updated, err)
    if not err then
      self.codex_goal = updated
    end
    callback(updated, err)
  end)
end

---@param status string
---@param callback fun(goal: table|nil, err: table|nil)
---@return table|nil
function Session:set_codex_goal_status(status, callback)
  if not self:_require_codex_goal(callback) then
    return nil
  end
  return self.client:update_codex_goal_status(self.session_id, status, function(updated, err)
    if not err then
      self.codex_goal = updated
    end
    callback(updated, err)
  end)
end

---@param callback fun(cleared: boolean|nil, err: table|nil)
---@return table|nil
function Session:clear_codex_goal(callback)
  if not self:_require_codex_goal(callback) then
    return nil
  end
  return self.client:clear_codex_goal(self.session_id, function(cleared, err)
    if cleared then
      self.codex_goal = nil
    end
    callback(cleared, err)
  end)
end

---Create a new durable session.
---@param opts? table
---@return table|nil session, table|nil err
function Session:create(opts)
  opts = opts or {}
  local targets, err = self:resolve_targets(opts)
  if not targets then
    return nil, err
  end
  local d = self.adapter.defaults or {}
  local body = { agent_id = targets.agent_id }
  if targets.host_id then
    body.host_id = targets.host_id
  end
  if targets.workspace then
    body.workspace = targets.workspace
  end
  if d.model_override then
    body.model_override = d.model_override
  end
  if d.reasoning_effort then
    body.reasoning_effort = d.reasoning_effort
  end
  if d.harness_override then
    body.harness_override = d.harness_override
  end
  -- Session labels are the correlation vehicle for external mappers (e.g. an
  -- Orchest bridge). Adapter `defaults.labels` may be a static table or a
  -- function evaluated here at create time so it can capture launch-context
  -- identity (the originating nvim session/tab); per-call `opts.labels` merge on
  -- top and win. Both are optional. Labels are also PATCHable later via update().
  local labels = {}
  local default_labels = d.labels
  if type(default_labels) == "function" then
    local lok, computed = pcall(default_labels)
    default_labels = (lok and type(computed) == "table") and computed or nil
  end
  if type(default_labels) == "table" then
    for k, v in pairs(default_labels) do
      labels[k] = v
    end
  end
  if type(opts.labels) == "table" then
    for k, v in pairs(opts.labels) do
      labels[k] = v
    end
  end
  if next(labels) then
    body.labels = labels
  end

  local s, cerr = self.client:create_session(body)
  if not s then
    return nil, cerr
  end
  self:_ingest_snapshot(s)
  return s
end

---Fork a source session into a new, independently-runnable session.
---
---Two server calls, mirroring the Web UI: (1) `POST /fork` deep-copies the
---source's items into a new UNBOUND session; (2) `POST /hosts/{id}/runners`
---binds + launches a runner for it. With `branch_name`, the launch creates a git
---worktree off the source's workspace so the fork runs isolated from the source
----- and, for a native harness, carries the source's transcript, which the host
---clones at boot (hence the fork MUST launch on the source's host).
---
---Static: does NOT mutate a Session instance. Returns the fork snapshot for a
---fresh chat to `:load` / `Chat:resume_omnigent`.
---@param client CodeCompanion.Omnigent.Client
---@param source table { session_id, host_id?, workspace? }
---@param opts? table { title?, up_to_response_id?, branch_name?, base_branch? }
---@return table|nil fork  Session snapshot (has `.id`), or nil on error.
---@return table|nil err  On a launch failure, carries `fork_session_id` (the
---  created-but-unbound fork) so the caller can offer a manual runner retry.
function Session.fork(client, source, opts)
  opts = opts or {}
  if not (source and source.session_id) then
    return nil, { message = "fork requires a source session id", code = "session_required" }
  end

  local fork, err = client:fork_session(source.session_id, {
    title = opts.title,
    up_to_response_id = opts.up_to_response_id,
  })
  if not fork or not fork.id then
    return nil, err or { message = "fork returned no session", code = "fork_failed" }
  end

  -- A host-launched source needs its fork bound to a runner before it can post;
  -- a headless (host_id=nil) source runs server-local and needs no launch.
  if source.host_id then
    if not source.workspace then
      return nil, {
        message = "source session has a host but no workspace; cannot launch the fork's runner",
        code = "workspace_required",
      }
    end
    -- base_branch=nil tells the server to branch from the source repo's current
    -- HEAD (see SessionGitOptions) -- exactly what a fork wants by default.
    local git = opts.branch_name and {
      branch_name = opts.branch_name,
      base_branch = opts.base_branch,
    } or nil
    local _, lerr = client:launch_runner(source.host_id, {
      session_id = fork.id,
      workspace = source.workspace,
      git = git,
    })
    if lerr then
      lerr.fork_session_id = fork.id
      return nil, lerr
    end
  end

  return fork
end

---Load an existing durable session: fetch snapshot + durable items.
---@param session_id string
---@return table|nil result { session, items }, table|nil err
function Session:load(session_id)
  local s, err = self.client:get_session(session_id)
  if not s then
    return nil, err
  end
  self:_ingest_snapshot(s)
  self.session_id = s.id or session_id
  local page = self.adapter.opts and self.adapter.opts.history_page_size
  local items, ierr = self.client:list_items(self.session_id, page and { limit = page } or nil)
  if not items then
    -- Fail loudly: an empty resume must be distinguishable from a failed fetch.
    return nil, ierr
  end
  -- Seed the seen sets so a later reconnect reconcile doesn't re-render history
  -- that was already hydrated on load.
  for _, item in ipairs(items) do
    self:_mark_seen(item.id, item.type, item.call_id)
  end
  return { session = s, items = items }
end

---Record that an item has materialised in the chat, under every key that could
---identify it later. Tolerates nils (an id-less or call-id-less item).
---@param item_id? string
---@param item_type? string
---@param call_id? string
function Session:_mark_seen(item_id, item_type, call_id)
  if item_id then
    self.seen_items[item_id] = true
  end
  if not call_id then
    return
  end
  if item_type == "function_call" then
    self.seen_calls[call_id] = true
  elseif item_type == "function_call_output" then
    self.seen_call_outputs[call_id] = true
  end
end

---Has this durable item (from GET /items) already been rendered into the chat?
---@param item table
---@return boolean
function Session:_already_seen(item)
  if item.id and self.seen_items[item.id] then
    return true
  end
  if not item.call_id then
    return false
  end
  if item.type == "function_call" then
    return self.seen_calls[item.call_id] == true
  elseif item.type == "function_call_output" then
    return self.seen_call_outputs[item.call_id] == true
  end
  return false
end

---Fold a normalised update into local state (status/model/usage tracking).
---@param u CodeCompanion.Omnigent.Update
function Session:_apply_state(u)
  if u.kind == "status" then
    self.status = u.status or self.status
  elseif
    u.kind == "turn_completed"
    or u.kind == "turn_failed"
    or u.kind == "turn_cancelled"
    or u.kind == "interrupted"
  then
    -- A turn ending means the session is no longer occupied, but `session.status`
    -- arrives as its OWN event and can trail the terminal response event. Anything
    -- gating on `busy()` right after a turn (compaction, most visibly) would see a
    -- stale "running" and refuse. Settle it here; a later status event still wins.
    self.status = "idle"
  elseif u.kind == "model" then
    if u.model then
      self.model = u.model
    end
    if u.reasoning_effort then
      self.reasoning_effort = u.reasoning_effort
    end
    if u.model_options then
      self.model_options = u.model_options
    end
  elseif u.kind == "usage" then
    self.usage = u.usage
  elseif u.kind == "compaction_completed" then
    -- MERGE rather than replace: the compaction event reports only the new
    -- context size, so a wholesale assignment would drop the cost / per-model
    -- breakdown that `session.usage` carries for update_metadata.
    if type(u.usage) == "table" and u.usage.context_tokens then
      local merged = type(self.usage) == "table" and vim.deepcopy(self.usage) or {}
      merged.context_tokens = u.usage.context_tokens
      self.usage = merged
    end
  elseif u.kind == "item_committed" then
    -- Single source of truth for "what durable items have materialised in this
    -- chat" -- populated for BOTH foreground and background updates so a
    -- reconnect reconcile can skip anything already rendered live.
    self:_mark_seen(u.item_id, u.item_type, u.call_id)
  elseif u.kind == "input_consumed" then
    -- A user message we (or another client) posted. `session.input.consumed`
    -- is the ONLY stream event carrying a user item's durable store id, so
    -- without this every reconcile replays the user's own prompt.
    self:_mark_seen(u.item_id, "message", nil)
  elseif u.kind == "elicitation" then
    self.pending_elicitations = self.pending_elicitations or {}
    if u.elicitation_id then
      self.pending_elicitations[u.elicitation_id] = u
    end
  elseif u.kind == "elicitation_resolved" then
    if self.pending_elicitations and u.elicitation_id then
      self.pending_elicitations[u.elicitation_id] = nil
    end
  elseif u.kind == "child_session" or u.kind == "child_session_created" then
    self.child_sessions = self.child_sessions or {}
    local id = u.child_session_id
    if id then
      self.child_sessions[id] = u.child or self.child_sessions[id] or { id = id }
    end
  end
end

---Deliver one state-folded update to the persistent lifecycle observer.
---@param update CodeCompanion.Omnigent.Update
function Session:_emit_lifecycle(update)
  if not lifecycle_kinds[update.kind] then
    return
  end
  local callback = self.callbacks.on_lifecycle
  if not callback then
    return
  end
  local ok, err = pcall(callback, update, self)
  if not ok then
    log:error("[Omnigent::Session] lifecycle callback failed: %s", tostring(err))
  end
end

---True if a foreground handler currently owns the stream (its callback is bound).
---@return boolean
function Session:_foreground_active()
  return self.callbacks.on_update ~= nil
end

---Is automatic reconnect-on-drop enabled for this session?
---@return boolean
function Session:_reconnect_enabled()
  local o = self.adapter.opts or {}
  return o.stream_reconnect == true or o.background_updates == true
end

---Route one decoded SSE event: reduce it, fold state, then deliver each update
---to the foreground callback if bound, else to the persistent observer.
---@param ev table
function Session:_on_event(ev)
  self:_arm_heartbeat() -- any traffic proves the stream is alive
  local ok, updates = pcall(function()
    return self.reducer:handle(ev)
  end)
  if not ok then
    if self.callbacks.on_error then
      self.callbacks.on_error({ message = "reducer error: " .. tostring(updates) })
    end
    return
  end
  for _, u in ipairs(updates) do
    self:_apply_state(u)
    self:_emit_lifecycle(u)
    if self.callbacks.on_update then
      self.callbacks.on_update(u)
    elseif self.observer then
      local ook, oerr = pcall(function()
        self.observer:handle_update(u)
      end)
      if not ook and self.callbacks.on_error then
        self.callbacks.on_error({ message = "observer error: " .. tostring(oerr) })
      end
    end
  end
end

---Open (or reopen) the underlying stream job. On a reconnect the in-flight text
---accumulator is reset so the stream-first replay rebuilds cleanly (the observer
---then appends only the new suffix); reducer identity/state is otherwise kept.
---@param reconnecting? boolean
function Session:_open_stream(reconnecting)
  if reconnecting then
    self.reducer:reset_inflight()
  end
  self._stream = self.client:stream_session(self.session_id, {
    on_event = function(ev)
      self:_on_event(ev)
    end,
    on_done = function(code)
      self:_on_stream_done(code)
    end,
  })
  self:_arm_heartbeat()
end

---Handle the stream job ending. Distinguishes an explicit stop from an
---unexpected drop; auto-reconnects only when the observer (not a live foreground
---turn) owns the stream, so the un-deduped foreground path can never double-render
---a replayed message.
---@param code? number
function Session:_on_stream_done(code)
  self._stream = nil
  self:_cancel_heartbeat()
  local was_foreground = self:_foreground_active()
  if was_foreground and not self._stopping then
    self:_emit_lifecycle({
      kind = "stream_error",
      response_id = self.reducer.current_response_id,
      error = { message = "omnigent stream ended before the turn completed", code = code },
    })
  end
  if self.callbacks.on_stream_end then
    self.callbacks.on_stream_end(code)
  end
  if self._stopping then
    self._stopping = false
    return
  end
  if not was_foreground and self.observer and self:_reconnect_enabled() then
    self:_schedule_reconnect()
  end
end

---Schedule a single deferred reconnect + reconcile (coalesced).
function Session:_schedule_reconnect()
  if self._reconnect_scheduled or self._stream then
    return
  end
  self._reconnect_scheduled = true
  local delay = (self.adapter.opts and self.adapter.opts.reconnect_delay) or 1000
  self._defer(function()
    self._reconnect_scheduled = false
    if self._stopping or self._stream then
      return
    end
    self:_open_stream(true)
    self:_reconcile()
  end, delay)
end

---After a reconnect, fetch durable items and render any the observer missed
---(completed while disconnected). In-flight text is NOT in /items (stream-first
---replay), so this only fills fully-missed, committed turns. Content already
---rendered live is skipped via seen_items.
---
---Runs ASYNCHRONOUSLY. This fires from the reconnect path, so it happens when
---the server is least likely to answer -- exactly when a blocking fetch would
---freeze the editor for the whole request budget. Nothing here needs the items
---to arrive before returning: every consumer is a side effect on the observer.
---
---`reconcile_timeout` is deliberately short. The client default is sized for a
---turn; a paginated GET issued while a dropped stream is reconnecting should
---give up quickly and let the next reconnect retry, rather than hold a curl job
---open across cycles.
function Session:_reconcile()
  if not self.observer or not self.session_id then
    return
  end
  -- Reconnects coalesce but can still overlap a fetch already in flight. A
  -- second pass would re-render nothing (seen_items dedups) but would bracket
  -- the observer with a nested begin/end pair, so drop it.
  if self._reconciling then
    return
  end
  local page = self.adapter.opts and self.adapter.opts.history_page_size
  local timeout = (self.adapter.opts and self.adapter.opts.reconcile_timeout) or 3000
  self._reconciling = true
  self.client:list_items_async(
    self.session_id,
    page and { limit = page } or nil,
    { timeout = timeout },
    function(items, _err)
      self._reconciling = false
      if not items or not self.observer or not self.session_id then
        return
      end
      self:_apply_reconciled_items(items)
    end
  )
end

---Render the durable items a reconcile fetched. Split out so the fetch can be
---async without indenting the whole body into a callback.
---@param items table[]
function Session:_apply_reconciled_items(items)
  if self.observer.reconcile_begin then
    self.observer:reconcile_begin()
  end
  for _, item in ipairs(items) do
    -- An item with no identifier at all can never be marked seen, so rendering
    -- it would duplicate on every subsequent reconcile. Skip it.
    local identifiable = item.id ~= nil or item.call_id ~= nil
    if identifiable and not self:_already_seen(item) then
      self:_mark_seen(item.id, item.type, item.call_id)
      -- While a background turn is mid-render, skip reconciling assistant message
      -- items: the one in flight is being rendered live (and its committed id may
      -- not line up with the id-less deltas), so re-rendering it would duplicate.
      -- User messages and other item types still reconcile.
      local skip = item.type == "message"
        and item.role ~= "user"
        and self.observer.has_partial
        and self.observer:has_partial()
      if not skip then
        pcall(function()
          self.observer:reconcile_item(item)
        end)
      end
    end
  end
  if self.observer.reconcile_end then
    pcall(function()
      self.observer:reconcile_end()
    end)
  end
end

---(Re)arm the heartbeat-timeout watchdog. Fires a forced reconnect if no stream
---traffic arrives within `stream_heartbeat_timeout` ms. Best-effort: skipped when
---no libuv timer is available (e.g. some headless test contexts).
function Session:_arm_heartbeat()
  local timeout = self.adapter.opts and self.adapter.opts.stream_heartbeat_timeout
  if not timeout or timeout <= 0 then
    return
  end
  local uv = vim.uv or vim.loop
  if not uv or not uv.new_timer then
    return
  end
  self:_cancel_heartbeat()
  local timer = uv.new_timer()
  if not timer then
    return
  end
  self._hb_timer = timer
  timer:start(timeout, 0, function()
    vim.schedule(function()
      self:_on_heartbeat_timeout()
    end)
  end)
end

---Cancel the heartbeat watchdog if armed.
function Session:_cancel_heartbeat()
  if self._hb_timer then
    pcall(function()
      self._hb_timer:stop()
      self._hb_timer:close()
    end)
    self._hb_timer = nil
  end
end

---Heartbeat expired: assume the stream is wedged and force a reconnect (unless a
---live foreground turn owns it -- yanking that would lose in-flight output).
function Session:_on_heartbeat_timeout()
  if not self._stream or self:_foreground_active() then
    return
  end
  log:debug("[Omnigent::Session] heartbeat timeout; forcing reconnect")
  pcall(function()
    self._stream.stop()
  end)
  self._stream = nil
  self:_cancel_heartbeat()
  if self.observer and self:_reconnect_enabled() then
    self:_schedule_reconnect()
  end
end

---Open the live SSE subscription (idempotent). Events flow through the reducer
---and each update is delivered to the foreground callback or the observer.
---@param opts? table
---@return table stream handle
function Session:start_stream(opts)
  if self._stream then
    return self._stream
  end
  self._stopping = false
  self:_open_stream()
  return self._stream
end

---Close the LOCAL SSE subscription. The durable server session is untouched. Sets
---the stopping flag so the resulting on_done does not trigger a reconnect.
function Session:stop_stream()
  self._stopping = true
  self:_cancel_heartbeat()
  if self._stream then
    pcall(function()
      self._stream.stop()
    end)
    self._stream = nil
  end
end

---True if the live stream is open.
---@return boolean
function Session:streaming()
  return self._stream ~= nil
end

---Post a foreground user message.
---@param text string
---@return table|nil, table|nil
function Session:post_message(text)
  local result, err = self.client:post_event(self.session_id, {
    type = "message",
    data = { role = "user", content = { { type = "input_text", text = text } } },
  })
  if result and result.pending_id then
    self.reducer:expect_input(result.pending_id)
  end
  return result, err
end

---Interrupt the active turn (does NOT stop or delete the session).
---@return table|nil, table|nil
function Session:interrupt()
  return self.client:post_event(self.session_id, { type = "interrupt", data = vim.empty_dict() })
end

---Whether a turn is currently occupying the session server-side. Compaction is
---refused in this state (the server raises CONFLICT); checking locally first
---turns a round-trip + stack trace into an immediate, readable message.
---@return boolean
function Session:busy()
  return self.status == "running" or self.status == "waiting"
end

---Request explicit context compaction of the durable session.
---
---Fires the request and returns; the outcome arrives on the SSE stream as
---`compaction_completed` / `compaction_failed` (see the client method for why the
---HTTP response is only an acknowledgement). The stream is opened first when it
---isn't already running -- without a subscription the terminal event would be
---published to nobody and the caller would wait forever.
---@param opts? table { timeout?: number }
---@param callback fun(ok: boolean, err: table|nil) Invoked on the HTTP outcome only
---@return boolean accepted, table|nil err Whether the request was dispatched at all
function Session:compact(opts, callback)
  opts = opts or {}
  if not self.session_id then
    return false, { message = "no durable session to compact" }
  end
  if self:busy() then
    return false, { message = "cannot compact while a turn is running; cancel or wait for it to finish" }
  end
  if not self:streaming() then
    self:start_stream()
  end
  self.client:compact_session(self.session_id, { timeout = opts.timeout }, function(_, err)
    if callback then
      callback(err == nil, err)
    end
  end)
  return true
end

---Request compaction by posting the agent's OWN `/compact` slash command as an
---ordinary user message.
---
---The CLI-backed harnesses intercept slash commands out of the input stream and
---compact their in-process context, which is the only compaction available to an
---SDK harness (the server refuses those, and the SDK control protocol has no
---compact verb). It is INVISIBLE to omnigent: no `response.compaction.*` events,
---no durable compaction item -- the CLI never tells anyone. Callers must therefore
---treat the turn ending as the completion signal.
---@return table|nil, table|nil
function Session:compact_via_slash()
  if not self.session_id then
    return nil, { message = "no durable session to compact" }
  end
  if self:busy() then
    return nil, { message = "cannot compact while a turn is running; cancel or wait for it to finish" }
  end
  if not self:streaming() then
    self:start_stream()
  end
  return self:post_message("/compact")
end

---Patch the session model (model_override).
---@param model string
---@return boolean, table|nil
function Session:set_model(model)
  if not self.session_id then
    self.model_override = model
    return true
  end
  local ok, err = self.client:update_session(self.session_id, { model_override = model })
  if ok then
    self.model_override = model
    self.model = model
    return true
  end
  return false, err
end

---Patch an arbitrary mutable session field (e.g. reasoning_effort, title, labels).
---@param key string
---@param value any
---@return boolean, table|nil
function Session:set_config(key, value)
  if not self.session_id then
    return false, { message = "no session" }
  end
  local ok, err = self.client:update_session(self.session_id, { [key] = value })
  if ok and key == "reasoning_effort" then
    self.reasoning_effort = value
  end
  return ok ~= nil, err
end

---Resolve an elicitation.
---@param elicitation_id string
---@param result table
---@return table|nil, table|nil
function Session:resolve_elicitation(elicitation_id, result)
  return self.client:resolve_elicitation(self.session_id, elicitation_id, result)
end

return Session
