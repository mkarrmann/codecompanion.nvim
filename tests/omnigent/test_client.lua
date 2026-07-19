local h = require("tests.helpers")
local new_set = MiniTest.new_set

local client = require("codecompanion.omnigent.client")

local T = new_set()

local function read_raw(name)
  return table.concat(vim.fn.readfile("tests/stubs/omnigent/" .. name), "\n")
end

-- ---- REST plumbing --------------------------------------------------------

T["builds request URL, method and JSON body"] = function()
  local captured
  local c = client.new({
    url = "http://host:6767",
    request = function(o)
      captured = o
      return { status = 200, body = vim.json.encode({ id = "conv_1", status = "idle" }) }
    end,
  })
  local s = c:create_session({ agent_id = "ag_1", host_id = "host_mac", workspace = "/tmp" })
  h.eq(s.id, "conv_1")
  h.eq(captured.method, "post")
  h.is_true(captured.url:find("/v1/sessions", 1, true) ~= nil)
  local sent = vim.json.decode(captured.body)
  h.eq(sent.agent_id, "ag_1")
  h.eq(sent.host_id, "host_mac")
end

T["decodes list fixtures"] = function()
  local c = client.new({
    request = function()
      return { status = 200, body = read_raw("readonly-agents.json") }
    end,
  })
  local agents = c:list_agents()
  h.is_true(#agents >= 1)
  h.is_true(agents[1].id ~= nil)
  h.is_true(agents[1].name ~= nil)
end

T["list_hosts returns the hosts array"] = function()
  local c = client.new({
    request = function()
      return { status = 200, body = read_raw("readonly-hosts.json") }
    end,
  })
  local hosts = c:list_hosts()
  h.is_true(#hosts >= 1)
  h.is_true(hosts[1].host_id ~= nil)
end

T["list_items returns the durable items"] = function()
  local c = client.new({
    request = function()
      return { status = 200, body = read_raw("items-lifecycle.json") }
    end,
  })
  local items = c:list_items("conv_1")
  h.eq(#items, 3)
end

T["post_event targets the events endpoint"] = function()
  local captured
  local c = client.new({
    request = function(o)
      captured = o
      return { status = 202, body = vim.json.encode({ queued = true, item_id = "msg_1" }) }
    end,
  })
  local res = c:post_event("conv_1", {
    type = "message",
    data = { role = "user", content = { { type = "input_text", text = "hi" } } },
  })
  h.eq(res.item_id, "msg_1")
  h.is_true(captured.url:find("/v1/sessions/conv_1/events", 1, true) ~= nil)
  h.eq(vim.json.decode(captured.body).type, "message")
end

T["normalises HTTP error responses"] = function()
  local c = client.new({
    request = function()
      return { status = 404, body = vim.json.encode({ error = { message = "not found", code = "nope" } }) }
    end,
  })
  local r, err = c:get_session("conv_none")
  h.eq(r, nil)
  h.eq(err.status, 404)
  h.is_true(err.message:find("not found", 1, true) ~= nil)
  h.eq(err.code, "nope")
end

T["normalises transport failures as retryable"] = function()
  local c = client.new({
    request = function()
      error("connection refused")
    end,
  })
  local r, err = c:list_hosts()
  h.eq(r, nil)
  h.eq(err.retryable, true)
end

T["default REST transport bypasses proxies only for loopback"] = function()
  local curl = require("plenary.curl")
  local original = curl.request
  local captured = {}
  curl.request = function(opts)
    captured[#captured + 1] = opts
    return { status = 200, body = '{"data":[]}' }
  end

  local ok, err = pcall(function()
    client.new({ url = "http://127.0.0.1:6767" }):list_agents()
    client.new({ url = "http://localhost:6767" }):list_agents()
    client.new({ url = "https://omnigent.example.com" }):list_agents()
  end)
  curl.request = original
  if not ok then
    error(err)
  end

  h.eq(captured[1].raw, { "--noproxy", "*" })
  h.eq(captured[2].raw, { "--noproxy", "*" })
  h.eq(captured[3].raw, nil)
end

T["default SSE transport bypasses proxies only for loopback"] = function()
  local original = vim.system
  local captured = {}
  vim.system = function(args)
    captured[#captured + 1] = args
    return { kill = function() end }
  end

  local ok, err = pcall(function()
    local callbacks = { on_event = function() end }
    client.new({ url = "http://127.0.0.1:6767" }):stream_session("one", callbacks)
    client.new({ url = "https://omnigent.example.com" }):stream_session("two", callbacks)
  end)
  vim.system = original
  if not ok then
    error(err)
  end

  h.eq(vim.list_slice(captured[1], 1, 4), { "curl", "--noproxy", "*", "-sS" })
  h.eq(vim.list_slice(captured[2], 1, 2), { "curl", "-sS" })
end

T["default asynchronous REST transport bypasses proxies only for loopback"] = function()
  local original = vim.system
  local captured = {}
  vim.system = function(args)
    captured[#captured + 1] = args
    return { kill = function() end }
  end

  local ok, err = pcall(function()
    client.new({ url = "http://127.0.0.1:6767" }):get_codex_goal("one", function() end)
    client.new({ url = "https://omnigent.example.com" }):get_codex_goal("two", function() end)
  end)
  vim.system = original
  if not ok then
    error(err)
  end

  h.is_true(vim.tbl_contains(captured[1], "--noproxy"))
  h.eq(vim.tbl_contains(captured[2], "--noproxy"), false)
end

T["Codex Goal methods use the asynchronous REST transport"] = function()
  local calls = {}
  local c = client.new({
    url = "http://host:6767",
    async_request = function(o)
      calls[#calls + 1] = o
      local response
      if o.method == "get" then
        response = { goal = { objective = "ship it", status = "active", tokens_used = 3 } }
      elseif o.method == "delete" then
        response = { cleared = true }
      else
        response = { goal = vim.tbl_extend("force", vim.json.decode(o.body), { tokens_used = 0 }) }
      end
      o.on_complete({ status = 200, body = vim.json.encode(response) })
      return { stop = function() end }
    end,
  })

  local fetched, updated, cleared
  c:get_codex_goal("conv_1", function(goal)
    fetched = goal
  end)
  c:set_codex_goal("conv_1", { objective = " ship it ", token_budget = 100, status = "active" }, function(goal)
    updated = goal
  end)
  c:update_codex_goal_status("conv_1", "paused", function(goal)
    updated = goal
  end)
  c:clear_codex_goal("conv_1", function(result)
    cleared = result
  end)

  h.eq(fetched.objective, "ship it")
  h.eq(updated.status, "paused")
  h.eq(cleared, true)
  h.eq(vim.tbl_map(function(call)
    return call.method
  end, calls), { "get", "put", "patch", "delete" })
  h.is_true(calls[1].url:find("/v1/sessions/conv_1/codex_goal", 1, true) ~= nil)
  h.eq(vim.json.decode(calls[2].body).objective, "ship it")
end

T["Codex Goal validates writable fields before transport"] = function()
  local called = false
  local c = client.new({
    async_request = function()
      called = true
    end,
  })
  local errors = {}
  c:set_codex_goal("conv_1", { objective = "", status = "active" }, function(_, err)
    errors[#errors + 1] = err.code
  end)
  c:set_codex_goal("conv_1", { objective = "ok", token_budget = 1.5 }, function(_, err)
    errors[#errors + 1] = err.code
  end)
  c:update_codex_goal_status("conv_1", "complete", function(_, err)
    errors[#errors + 1] = err.code
  end)
  h.eq(errors, { "invalid_goal", "invalid_goal_budget", "invalid_goal_status" })
  h.eq(called, false)
end

T["asynchronous REST failures use normalised errors"] = function()
  local c = client.new({
    async_request = function(o)
      o.on_complete({ status = 503, body = '{"error":{"message":"runner asleep","code":"offline"}}' })
    end,
  })
  local got
  c:get_codex_goal("conv_1", function(_, err)
    got = err
  end)
  h.eq(got.status, 503)
  h.eq(got.code, "offline")
  h.eq(got.retryable, true)
end

-- ---- Agent resolution (no prefix sniffing) --------------------------------

T["resolve_agent: id match wins, then unique name"] = function()
  local c = client.new({})
  local agents = { { id = "ag_1", name = "debby" }, { id = "ag_2", name = "claude-native-ui" } }
  h.eq(c:resolve_agent("ag_2", { agents = agents }), "ag_2")
  h.eq(c:resolve_agent("debby", { agents = agents }), "ag_1")

  local id, err = c:resolve_agent("missing", { agents = agents })
  h.eq(id, nil)
  h.eq(err.code, "agent_not_found")
end

T["resolve_agent: bare-hex id resolves without prefix sniffing"] = function()
  local c = client.new({})
  -- A HEAD-server bare-hex agent id must still resolve by direct id match.
  local agents = { { id = "eac9e787e68ae6774d77e618031c287a", name = "x" } }
  h.eq(c:resolve_agent("eac9e787e68ae6774d77e618031c287a", { agents = agents }), "eac9e787e68ae6774d77e618031c287a")
end

-- ---- Host resolution (FAIL-CLOSED) ----------------------------------------

local THREE_HOSTS = {
  { host_id = "host_mac", name = "MacBook-Pro.local", status = "online" },
  { host_id = "host_d1", name = "devvm20365.cco0.facebook.com", status = "online" },
  { host_id = "host_d2", name = "devvm36111.ftw0.facebook.com", status = "online" },
}

T["resolve_host auto: unique FQDN match on this machine"] = function()
  local c = client.new({ hostname = "MacBook-Pro.local" })
  h.eq(c:resolve_host("auto", { hosts = THREE_HOSTS }), "host_mac")
end

T["resolve_host auto: fails CLOSED when nothing matches"] = function()
  local c = client.new({ hostname = "some-unregistered-box" })
  local id, err = c:resolve_host("auto", { hosts = THREE_HOSTS })
  h.eq(id, nil)
  h.eq(err.code, "host_unresolved")
end

T["resolve_host auto: fails CLOSED on ambiguous match"] = function()
  local dup = {
    { host_id = "a", name = "dev.foo.com", status = "online" },
    { host_id = "b", name = "dev.bar.com", status = "online" },
  }
  local c = client.new({ hostname = "dev" })
  local id, err = c:resolve_host("auto", { hosts = dup })
  h.eq(id, nil)
  h.eq(err.code, "host_ambiguous")
end

T["resolve_host: explicit id and name"] = function()
  local c = client.new({})
  h.eq(c:resolve_host("host_d1", { hosts = THREE_HOSTS }), "host_d1")
  h.eq(c:resolve_host("devvm20365.cco0.facebook.com", { hosts = THREE_HOSTS }), "host_d1")
end

T["resolve_host: explicit offline host is refused"] = function()
  local c = client.new({})
  local off = { { host_id = "x", name = "MacBook-Pro.local", status = "offline" } }
  local id, err = c:resolve_host("MacBook-Pro.local", { hosts = off })
  h.eq(id, nil)
  h.eq(err.code, "host_offline")
end

-- ---- Streaming (injected job) ---------------------------------------------

T["stream_session decodes events via injected job"] = function()
  local blob = read_raw("sse-clean-full.txt")
  local c = client.new({
    job = function(o)
      o.on_stdout(blob)
      o.on_exit(0)
      return { stop = function() end }
    end,
  })
  local evs, done = {}, nil
  c:stream_session("conv_1", {
    on_event = function(e)
      evs[#evs + 1] = e
    end,
    on_done = function(code)
      done = code
    end,
  })
  h.eq(#evs, 13)
  h.eq(done, 0)
end

return T
