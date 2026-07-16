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
---@field callbacks table { on_update?, on_error?, on_stream_end? }
---@field _stream? table
local Session = {}
Session.__index = Session

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
    _stream = nil,
  }, Session)
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

---Fold a session snapshot (from create/get) into this runtime's state.
---@param s table
function Session:_ingest_snapshot(s)
  if type(s) ~= "table" then
    return
  end
  self.session_id = s.id or self.session_id
  self.agent_id = s.agent_id or self.agent_id
  self.host_id = s.host_id or self.host_id
  self.workspace = s.workspace or self.workspace
  self.status = s.status or self.status
  self.model = s.llm_model or s.model or self.model
  self.model_override = s.model_override or self.model_override
  self.reasoning_effort = s.reasoning_effort or self.reasoning_effort
  self.model_options = s.model_options or self.model_options
  self.title = s.title or self.title
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
  end
end

---Open the live SSE subscription (idempotent). Events flow through the reducer
---and each update is delivered to callbacks.on_update.
---@param opts? table
---@return table stream handle
function Session:start_stream(opts)
  if self._stream then
    return self._stream
  end
  opts = opts or {}
  self._stream = self.client:stream_session(self.session_id, {
    on_event = function(ev)
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
        if self.callbacks.on_update then
          self.callbacks.on_update(u)
        end
      end
    end,
    on_done = function(code)
      self._stream = nil
      if self.callbacks.on_stream_end then
        self.callbacks.on_stream_end(code)
      end
    end,
  })
  return self._stream
end

---Close the LOCAL SSE subscription. The durable server session is untouched.
function Session:stop_stream()
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
