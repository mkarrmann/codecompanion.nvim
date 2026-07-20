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
---@field host_id? string
---@field workspace? string
---@field status? string
---@field model? string
---@field model_override? string
---@field reasoning_effort? string
---@field model_options? table
---@field title? string
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
      job = opts.job,
    })
  return setmetatable({
    client = client,
    adapter = adapter or {},
    reducer = Events.new(),
    callbacks = opts.callbacks or {},
    observer = nil,
    seen_items = {},
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
  self.host_id = nn(s.host_id) or self.host_id
  self.workspace = nn(s.workspace) or self.workspace
  self.status = nn(s.status) or self.status
  self.model = nn(s.llm_model) or nn(s.model) or self.model
  self.model_override = nn(s.model_override) or self.model_override
  self.reasoning_effort = nn(s.reasoning_effort) or self.reasoning_effort
  self.model_options = nn(s.model_options) or self.model_options
  self.title = nn(s.title) or self.title
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
  -- Seed the seen-items set so a later reconnect reconcile doesn't re-render
  -- history that was already hydrated on load.
  for _, item in ipairs(items) do
    if item.id then
      self.seen_items[item.id] = true
    end
  end
  return { session = s, items = items }
end

---Fold a normalised update into local state (status/model/usage tracking).
---@param u CodeCompanion.Omnigent.Update
function Session:_apply_state(u)
  if u.kind == "status" then
    self.status = u.status or self.status
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
  elseif u.kind == "item_committed" then
    -- Single source of truth for "what durable items have materialised in this
    -- chat" -- populated for BOTH foreground and background updates so a
    -- reconnect reconcile can skip anything already rendered live.
    if u.item_id then
      self.seen_items[u.item_id] = true
    end
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
function Session:_reconcile()
  if not self.observer or not self.session_id then
    return
  end
  local page = self.adapter.opts and self.adapter.opts.history_page_size
  local items = self.client:list_items(self.session_id, page and { limit = page } or nil)
  if not items then
    return
  end
  for _, item in ipairs(items) do
    local id = item.id
    if id and not self.seen_items[id] then
      self.seen_items[id] = true
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
  return self.client:post_event(self.session_id, {
    type = "message",
    data = { role = "user", content = { { type = "input_text", text = text } } },
  })
end

---Interrupt the active turn (does NOT stop or delete the session).
---@return table|nil, table|nil
function Session:interrupt()
  return self.client:post_event(self.session_id, { type = "interrupt", data = vim.empty_dict() })
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
