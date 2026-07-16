--=============================================================================
-- Omnigent REST + SSE client
--
-- Owns all HTTP conversation with an omnigent-compatible server. It is a thin,
-- transport-injectable layer: `opts.request` (sync REST) and `opts.job` (async
-- stream) can be swapped in tests so no socket is needed. All ids are treated as
-- opaque strings (the deployed server emits conv_/ag_/host_ prefixes, but HEAD
-- emits bare hex -- never branch on prefix shape).
--
-- Host resolution is FAIL-CLOSED: `host = "auto"` resolves only when exactly one
-- online host matches this machine, otherwise it refuses rather than sending
-- host_id=nil (which the server would silently run locally, skipping workspace
-- validation -- the "silent downgrade" the design forbids).
--=============================================================================

local M = {}

---@class CodeCompanion.Omnigent.Client
---@field url string Base URL, e.g. http://127.0.0.1:6767
---@field headers table Default headers
---@field timeout number Request timeout (ms)
---@field hostname string This machine's hostname/FQDN (overridable for tests)
---@field _request fun(o: table): table Injectable REST transport
---@field _job? fun(o: table): table Injectable stream-job spawner
local Client = {}
Client.__index = Client

--- Default synchronous REST transport (plenary.curl).
---@param o table { url, method, headers, body, timeout }
---@return table { status: number, body: string }
local function default_request(o)
  local curl = require("plenary.curl")
  return curl.request({
    url = o.url,
    method = (o.method or "GET"):lower(),
    headers = o.headers,
    body = o.body,
    timeout = o.timeout,
  })
end

--- Default async stream-job spawner (curl -N via vim.system). Feeds raw stdout
--- chunks to o.on_stdout and calls o.on_exit(code) when the process ends.
---@param o table
---@return table { stop: fun() }
local function default_job(o)
  local args = { "curl", "-sS", "-N", o.url }
  for k, v in pairs(o.headers or {}) do
    table.insert(args, "-H")
    table.insert(args, string.format("%s: %s", k, v))
  end
  local proc = vim.system(args, {
    stdout = function(_, data)
      if data then
        vim.schedule(function()
          o.on_stdout(data)
        end)
      end
    end,
  }, function(res)
    vim.schedule(function()
      o.on_exit(res.code)
    end)
  end)
  return {
    stop = function()
      pcall(function()
        proc:kill(15)
      end)
    end,
  }
end

---@param opts? table { url?, headers?, timeout?, hostname?, request?, job? }
---@return CodeCompanion.Omnigent.Client
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    url = (opts.url or "http://127.0.0.1:6767"):gsub("/$", ""),
    headers = opts.headers or {},
    timeout = opts.timeout or 30000,
    hostname = opts.hostname or (vim.uv or vim.loop).os_gethostname(),
    _request = opts.request or default_request,
    _job = opts.job or default_job,
  }, Client)
end

---URL-encode a query table.
---@param params table
---@return string
local function encode_query(params)
  local parts = {}
  for k, v in pairs(params) do
    if v ~= nil then
      parts[#parts + 1] = tostring(k) .. "=" .. vim.uri_encode(tostring(v))
    end
  end
  return table.concat(parts, "&")
end

---Turn an HTTP failure into a normalised error.
---@param status? number
---@param decoded? table
---@param raw? string
---@return table
local function normalize_error(status, decoded, raw)
  local msg
  if decoded then
    local e = decoded.error
    msg = (type(e) == "table" and (e.message or e.detail)) or (type(e) == "string" and e) or decoded.message or decoded.detail
  end
  msg = msg or raw or ("HTTP " .. tostring(status))
  local action
  if status == 401 or status == 403 then
    action = "Access denied by the omnigent server."
  elseif status == 404 then
    action = "Resource not found -- the session/agent/host may not exist."
  elseif status == 503 then
    action = "Runner unavailable -- the session may have no bound/online host."
  elseif status and status >= 500 then
    action = "Server error -- retry may help."
  end
  return {
    message = tostring(msg),
    status = status,
    code = decoded and decoded.error and type(decoded.error) == "table" and decoded.error.code or nil,
    retryable = status == 429 or (status ~= nil and status >= 500) or false,
    action = action,
  }
end

---Perform a REST request. Returns the decoded body on success, or nil + error.
---@param method string
---@param path string
---@param opts? table { query?, body?, headers? }
---@return table|nil result
---@return table|nil err
function Client:request(method, path, opts)
  opts = opts or {}
  local url = self.url .. path
  if opts.query and next(opts.query) then
    url = url .. "?" .. encode_query(opts.query)
  end
  local headers = vim.tbl_extend("force", {
    ["content-type"] = "application/json",
    ["accept"] = "application/json",
  }, self.headers, opts.headers or {})

  local body = opts.body ~= nil and vim.json.encode(opts.body) or nil

  local ok, resp = pcall(self._request, {
    url = url,
    method = method,
    headers = headers,
    body = body,
    timeout = self.timeout,
  })
  if not ok or type(resp) ~= "table" then
    return nil, {
      message = "request failed: " .. tostring(resp),
      retryable = true,
      action = "Is the omnigent server reachable at " .. self.url .. "?",
    }
  end

  local status = resp.status or resp.code
  local raw = resp.body
  local decoded
  if type(raw) == "string" and raw ~= "" then
    local dok, d = pcall(vim.json.decode, raw)
    if dok then
      decoded = d
    end
  end

  if not status or status < 200 or status >= 300 then
    return nil, normalize_error(status, decoded, raw)
  end
  return decoded == nil and {} or decoded
end

--- Follow OpenAI-style pagination, collecting every `data` element (capped).
---@param path string
---@param params? table
---@param max_pages? integer
---@return table[]|nil, table|nil
function Client:_list_all(path, params, max_pages)
  params = params or {}
  max_pages = max_pages or 20
  local out = {}
  local after = nil
  for _ = 1, max_pages do
    local q = vim.tbl_extend("force", {}, params)
    if after then
      q.after = after
    end
    local body, err = self:request("get", path, { query = q })
    if not body then
      return nil, err
    end
    local data = body.data or {}
    vim.list_extend(out, data)
    if not body.has_more or not body.last_id then
      break
    end
    after = body.last_id
  end
  return out
end

-- ---- REST resource methods -------------------------------------------------

---@return table[]|nil agents, table|nil err
function Client:list_agents()
  return self:_list_all("/v1/agents")
end

---@return table[]|nil hosts, table|nil err
function Client:list_hosts()
  local body, err = self:request("get", "/v1/hosts")
  if not body then
    return nil, err
  end
  return body.hosts or body.data or {}
end

---@param body table
---@return table|nil session, table|nil err
function Client:create_session(body)
  return self:request("post", "/v1/sessions", { body = body })
end

---@param params? table
---@return table[]|nil sessions, table|nil err
function Client:list_sessions(params)
  return self:_list_all("/v1/sessions", params)
end

---@param session_id string
---@return table|nil session, table|nil err
function Client:get_session(session_id)
  return self:request("get", "/v1/sessions/" .. session_id)
end

---@param session_id string
---@param body table
---@return table|nil session, table|nil err
function Client:update_session(session_id, body)
  return self:request("patch", "/v1/sessions/" .. session_id, { body = body })
end

---Fetch durable items, following pagination (fails loudly on any page error).
---@param session_id string
---@param params? table
---@return table[]|nil items, table|nil err
function Client:list_items(session_id, params)
  return self:_list_all("/v1/sessions/" .. session_id .. "/items", params)
end

---Post an inbound event (message / interrupt / approval / ...).
---@param session_id string
---@param event table
---@return table|nil result, table|nil err
function Client:post_event(session_id, event)
  return self:request("post", "/v1/sessions/" .. session_id .. "/events", { body = event })
end

---Resolve an elicitation (accept/decline/cancel).
---@param session_id string
---@param elicitation_id string
---@param result table { action: string, content?: table }
---@return table|nil, table|nil
function Client:resolve_elicitation(session_id, elicitation_id, result)
  return self:request(
    "post",
    "/v1/sessions/" .. session_id .. "/elicitations/" .. elicitation_id .. "/resolve",
    { body = result }
  )
end

-- ---- Resolution (opaque ids, no prefix sniffing) ---------------------------

---Resolve an agent spec (id or name) to an agent id. Tries id match first, then
---unique name match. Never branches on id prefix shape.
---@param spec string
---@param opts? table { agents?: table[] }
---@return string|nil agent_id, table|nil err
function Client:resolve_agent(spec, opts)
  opts = opts or {}
  local agents = opts.agents
  if not agents then
    local list, err = self:list_agents()
    if not list then
      return nil, err
    end
    agents = list
  end
  -- Direct id match first.
  for _, a in ipairs(agents) do
    if a.id == spec then
      return a.id
    end
  end
  -- Unique name match.
  local matches = {}
  for _, a in ipairs(agents) do
    if a.name == spec then
      matches[#matches + 1] = a
    end
  end
  if #matches == 1 then
    return matches[1].id
  elseif #matches == 0 then
    return nil, { message = "No omnigent agent matches '" .. spec .. "'", code = "agent_not_found" }
  end
  return nil, { message = "Multiple omnigent agents named '" .. spec .. "'; specify an id", code = "agent_ambiguous" }
end

---Lowercased leading DNS label (host part before the first dot).
---@param name string
---@return string
local function leading_label(name)
  return (tostring(name):lower():gsub("%..*$", ""))
end

---Resolve a host spec to a host id. FAIL-CLOSED for "auto": exactly one online
---host must match this machine, else it refuses. Returns nil,err on refusal.
---@param spec string|nil "auto" | host id | host name/FQDN
---@param opts? table { hosts?: table[], hostname?: string, require_online?: boolean }
---@return string|nil host_id, table|nil err
function Client:resolve_host(spec, opts)
  opts = opts or {}
  spec = spec or "auto"
  local hosts = opts.hosts
  if not hosts then
    local list, err = self:list_hosts()
    if not list then
      return nil, err
    end
    hosts = list
  end

  local function online(h)
    return h.status == nil or h.status == "online"
  end

  if spec ~= "auto" then
    -- Explicit id match first.
    for _, h in ipairs(hosts) do
      if h.host_id == spec then
        return h.host_id
      end
    end
    -- Then explicit name / FQDN match.
    local named = {}
    for _, h in ipairs(hosts) do
      if h.name == spec or leading_label(h.name) == leading_label(spec) then
        named[#named + 1] = h
      end
    end
    local online_named = vim.tbl_filter(online, named)
    if #online_named == 1 then
      return online_named[1].host_id
    elseif #named == 1 then
      -- Single match but offline: refuse (don't run on a dead host).
      return nil, {
        message = "Host '" .. spec .. "' is not online",
        code = "host_offline",
        action = "Bring the host online or pick another.",
      }
    elseif #named == 0 then
      return nil, { message = "No omnigent host matches '" .. spec .. "'", code = "host_not_found" }
    end
    return nil, {
      message = "Multiple hosts match '" .. spec .. "'; specify a host id",
      code = "host_ambiguous",
    }
  end

  -- spec == "auto": match this machine's FQDN, fail closed on ambiguity.
  local fqdn = opts.hostname or self.hostname or ""
  local candidates = {}
  for _, h in ipairs(hosts) do
    if online(h) and (h.name == fqdn or leading_label(h.name) == leading_label(fqdn)) then
      candidates[#candidates + 1] = h
    end
  end
  if #candidates == 1 then
    return candidates[1].host_id
  elseif #candidates == 0 then
    return nil, {
      message = "Could not resolve this machine ('" .. fqdn .. "') to an online omnigent host",
      code = "host_unresolved",
      action = "Register this host with omnigent, or set an explicit host in the adapter config.",
    }
  end
  return nil, {
    message = "'" .. fqdn .. "' matches " .. #candidates .. " online hosts; set an explicit host id",
    code = "host_ambiguous",
    action = "Refusing to guess -- pick a host id to avoid running on the wrong machine.",
  }
end

-- ---- Streaming ------------------------------------------------------------

---Subscribe to the live SSE stream. Returns a handle with stop(). Decoded events
---are delivered to opts.on_event; opts.on_done(code) fires when the stream ends.
---@param session_id string
---@param opts table { on_event: fun(ev), on_done?: fun(code), headers?: table }
---@return table handle { stop: fun() }
function Client:stream_session(session_id, opts)
  local sse = require("codecompanion.omnigent.sse")
  local parser = sse.new_parser()
  local headers = vim.tbl_extend("force", { accept = "text/event-stream" }, self.headers, opts.headers or {})
  return self._job({
    url = self.url .. "/v1/sessions/" .. session_id .. "/stream",
    headers = headers,
    on_stdout = function(chunk)
      for _, ev in ipairs(parser:feed_decoded(chunk)) do
        opts.on_event(ev)
      end
    end,
    on_exit = function(code)
      for _, ev in ipairs(parser:finish_decoded()) do
        opts.on_event(ev)
      end
      if opts.on_done then
        opts.on_done(code)
      end
    end,
  })
end

return M
