local h = require("tests.helpers")
local new_set = MiniTest.new_set

local client = require("codecompanion.omnigent.client")
local session = require("codecompanion.omnigent.session")

local T = new_set()

local function read_raw(name)
  return table.concat(vim.fn.readfile("tests/stubs/omnigent/" .. name), "\n")
end

---A recording REST router keyed on method + path.
local function router(cap)
  return function(o)
    local m, url = o.method, o.url
    if url:find("/v1/agents", 1, true) then
      return { status = 200, body = read_raw("readonly-agents.json") }
    elseif url:find("/v1/hosts", 1, true) then
      return { status = 200, body = vim.json.encode({ hosts = cap.hosts or {} }) }
    elseif m == "post" and url:find("/events", 1, true) then
      cap.event = o
      return { status = 202, body = vim.json.encode({ queued = true, item_id = "msg_x" }) }
    elseif m == "post" and url:find("/v1/sessions", 1, true) then
      cap.create = o
      return { status = 200, body = vim.json.encode(cap.create_resp or { id = "conv_1", status = "idle" }) }
    elseif m == "patch" and url:find("/v1/sessions/", 1, true) then
      cap.patch = o
      return { status = 200, body = vim.json.encode({ id = "conv_1", model_override = "patched" }) }
    elseif m == "get" and url:find("/items", 1, true) then
      return { status = 200, body = read_raw("items-lifecycle.json") }
    elseif m == "get" and url:find("/v1/sessions/", 1, true) then
      return { status = 200, body = read_raw("session-create.json") }
    end
    return { status = 404, body = "{}" }
  end
end

local function make(defaults, hostname, cap)
  cap = cap or {}
  local c = client.new({ url = "http://x", hostname = hostname, request = router(cap), job = cap.job })
  local adapter = { type = "omnigent", url = "http://x", defaults = defaults, opts = {} }
  return session.new({ adapter = adapter, client = c, callbacks = cap.cb or {} }), cap
end

local MAC = { { host_id = "host_mac", name = "MacBook-Pro.local", status = "online" } }
local MAC_AND_DEVVM = {
  { host_id = "host_mac", name = "MacBook-Pro.local", status = "online" },
  { host_id = "host_d1", name = "devvm36111.ftw0.facebook.com", status = "online" },
}

T["create resolves agent/host/workspace and posts the right body"] = function()
  local cap = { hosts = MAC }
  local s = make({ agent = "claude-native-ui", host = "auto", workspace = "auto" }, "MacBook-Pro.local", cap)
  local sess, err = s:create()
  h.eq(err, nil)
  h.eq(sess.id, "conv_1")
  h.eq(s.session_id, "conv_1")

  local body = vim.json.decode(cap.create.body)
  h.is_true(body.agent_id ~= nil) -- resolved by name to an id
  h.eq(body.host_id, "host_mac")
  h.eq(body.workspace, vim.fn.getcwd())
end

T["create FAILS CLOSED when host='auto' cannot resolve"] = function()
  local cap = { hosts = MAC_AND_DEVVM }
  local s = make({ agent = "claude-native-ui", host = "auto", workspace = "auto" }, "not-a-registered-host", cap)
  local sess, err = s:create()
  h.eq(sess, nil)
  h.eq(err.code, "host_unresolved")
  -- Crucially: no session was created.
  h.eq(cap.create, nil)
end

T["create refuses workspace='auto' on a remote host"] = function()
  local cap = { hosts = MAC_AND_DEVVM }
  local s = make(
    { agent = "claude-native-ui", host = "devvm36111.ftw0.facebook.com", workspace = "auto" },
    "MacBook-Pro.local",
    cap
  )
  local sess, err = s:create()
  h.eq(sess, nil)
  h.eq(err.code, "workspace_required")
  h.eq(cap.create, nil)
end

T["create allows an explicit workspace on a remote host"] = function()
  local cap = { hosts = MAC_AND_DEVVM }
  local s = make({
    agent = "claude-native-ui",
    host = "devvm36111.ftw0.facebook.com",
    workspace = "/home/user/fbsource",
  }, "MacBook-Pro.local", cap)
  local sess, err = s:create()
  h.eq(err, nil)
  h.eq(sess.id, "conv_1")
  local body = vim.json.decode(cap.create.body)
  h.eq(body.host_id, "host_d1")
  h.eq(body.workspace, "/home/user/fbsource")
end

T["host='none' opts into a headless session"] = function()
  local cap = { hosts = MAC }
  local s = make({ agent = "claude-native-ui", host = "none", workspace = "auto" }, "MacBook-Pro.local", cap)
  local sess, err = s:create()
  h.eq(err, nil)
  local body = vim.json.decode(cap.create.body)
  h.eq(body.host_id, nil)
  h.eq(body.workspace, nil)
end

T["create sends adapter labels (static, with opts merged on top)"] = function()
  local cap = { hosts = MAC }
  local s = make(
    { agent = "claude-native-ui", host = "auto", workspace = "auto", labels = { a = "1", b = "2" } },
    "MacBook-Pro.local",
    cap
  )
  s:create({ labels = { b = "override", c = "3" } })
  local body = vim.json.decode(cap.create.body)
  h.eq(body.labels.a, "1")
  h.eq(body.labels.b, "override") -- per-call opts win
  h.eq(body.labels.c, "3")
end

T["create evaluates a labels function at create time"] = function()
  local cap = { hosts = MAC }
  local s = make({
    agent = "claude-native-ui",
    host = "auto",
    workspace = "auto",
    labels = function()
      return { ["orchest.nvim_session"] = "sess1" }
    end,
  }, "MacBook-Pro.local", cap)
  s:create()
  local body = vim.json.decode(cap.create.body)
  h.eq(body.labels["orchest.nvim_session"], "sess1")
end

T["load ingests the snapshot and returns durable items"] = function()
  local cap = { hosts = MAC }
  local s = make({ agent = "claude-native-ui" }, "MacBook-Pro.local", cap)
  local result, err = s:load("conv_1")
  h.eq(err, nil)
  h.eq(#result.items, 3)
  -- The loaded snapshot's canonical id wins over the requested id.
  h.eq(s.session_id, result.session.id)
  -- session-create.json carries model_options and status.
  h.is_true(s.model_options ~= nil)
  h.eq(s.context_window, 1000000)
end

T["create ingests context and per-model usage from the snapshot"] = function()
  local cap = {
    hosts = MAC,
    create_resp = {
      id = "conv_1",
      status = "idle",
      context_window = 200000,
      usage_by_model = { codex = { input_tokens = 10 } },
    },
  }
  local s = make({ agent = "claude-native-ui", host = "auto", workspace = "auto" }, "MacBook-Pro.local", cap)

  local _, err = s:create()

  h.eq(err, nil)
  h.eq(s.context_window, 200000)
  h.eq(s.usage_by_model.codex.input_tokens, 10)
end

T["snapshot identity gates Codex Goal support by wrapper label"] = function()
  local s = make({ agent = "codex-native-ui" }, "MacBook-Pro.local", { hosts = MAC })
  s:_ingest_snapshot({
    id = "conv_goal",
    agent_id = "ag_codex",
    agent_name = "codex-native-ui",
    harness = "codex-native",
    labels = { ["omnigent.wrapper"] = "codex-native-ui", ["omnigent.ui"] = "terminal" },
  })
  h.eq(s.agent_name, "codex-native-ui")
  h.eq(s.harness, "codex-native")
  h.eq(s:supports_codex_goal(), true)

  s.labels["omnigent.wrapper"] = "custom-native"
  h.eq(s:supports_codex_goal(), false)
end

T["session Goal methods cache successful results"] = function()
  local s = make({ agent = "codex-native-ui" }, "MacBook-Pro.local", { hosts = MAC })
  s.session_id = "conv_goal"
  s.labels = { ["omnigent.wrapper"] = "codex-native-ui" }
  s.client.get_codex_goal = function(_, id, callback)
    h.eq(id, "conv_goal")
    callback({ objective = "one", status = "active" })
  end
  s.client.update_codex_goal_status = function(_, _, status, callback)
    callback({ objective = "one", status = status })
  end
  s.client.clear_codex_goal = function(_, _, callback)
    callback(true)
  end

  s:get_codex_goal(function(goal)
    h.eq(goal.objective, "one")
  end)
  h.eq(s.codex_goal.status, "active")
  s:set_codex_goal_status("paused", function() end)
  h.eq(s.codex_goal.status, "paused")
  s:clear_codex_goal(function() end)
  h.eq(s.codex_goal, nil)
end

T["session Goal methods reject unsupported wrappers"] = function()
  local s = make({ agent = "codex-native-ui" }, "MacBook-Pro.local", { hosts = MAC })
  s.session_id = "conv_goal"
  s.labels = { ["omnigent.wrapper"] = "not-codex-native-ui" }
  local got
  s:get_codex_goal(function(_, err)
    got = err
  end)
  h.eq(got.code, "goal_unsupported")
end

T["load fails loudly when item fetch errors (no silent empty)"] = function()
  local c = client.new({
    url = "http://x",
    hostname = "MacBook-Pro.local",
    request = function(o)
      if o.url:find("/items", 1, true) then
        return { status = 500, body = '{"error":{"message":"boom"}}' }
      elseif o.url:find("/v1/sessions/", 1, true) then
        return { status = 200, body = read_raw("session-create.json") }
      end
      return { status = 404, body = "{}" }
    end,
  })
  local s = session.new({ adapter = { type = "omnigent", url = "http://x", defaults = {}, opts = {} }, client = c })
  local r, err = s:load("conv_1")
  h.eq(r, nil)
  h.is_true(err ~= nil)
end

T["ingests JSON null fields as nil (no vim.NIL model poisoning)"] = function()
  local c = client.new({
    url = "http://x",
    hostname = "MacBook-Pro.local",
    request = function(o)
      if o.url:find("/v1/agents", 1, true) then
        return { status = 200, body = read_raw("readonly-agents.json") }
      elseif o.url:find("/v1/hosts", 1, true) then
        return { status = 200, body = vim.json.encode({ hosts = MAC }) }
      elseif o.method == "post" and o.url:find("/v1/sessions", 1, true) then
        -- Server reports several fields as JSON null (common with claude-sdk).
        return {
          status = 200,
          body = '{"id":"conv_1","status":"idle","llm_model":null,"model_override":null,"title":null}',
        }
      end
      return { status = 404, body = "{}" }
    end,
  })
  local s = session.new({
    adapter = {
      type = "omnigent",
      url = "http://x",
      defaults = { agent = "claude-native-ui", host = "auto", workspace = "auto" },
      opts = {},
    },
    client = c,
  })
  local _, err = s:create()
  h.eq(err, nil)
  -- Null decodes to nil (absent), NOT vim.NIL (which is truthy and would win the
  -- `model_override or model or "default"` chain).
  h.eq(s.model, nil)
  h.eq(s.model_override, nil)
  h.eq(s.title, nil)
  h.eq(s.model_override or s.model or "default", "default")
end

T["start_stream pipes reducer updates to on_update"] = function()
  local updates = {}
  local blob = read_raw("sse-clean-full.txt")
  local cap = {
    hosts = MAC,
    cb = {
      on_update = function(u)
        updates[#updates + 1] = u
      end,
    },
    job = function(o)
      o.on_stdout(blob)
      o.on_exit(0)
      return { stop = function() end }
    end,
  }
  local s = make({ agent = "claude-native-ui" }, "MacBook-Pro.local", cap)
  s.session_id = "conv_1"
  s:start_stream()

  local kinds = vim.tbl_map(function(u)
    return u.kind
  end, updates)
  h.is_true(vim.tbl_contains(kinds, "message_delta"))
  h.is_true(vim.tbl_contains(kinds, "turn_completed"))
  -- state folded from the status event
  h.eq(s.status, "idle")
end

T["lifecycle observes folded state once before foreground delivery"] = function()
  local order = {}
  local observed
  local cap = {
    hosts = MAC,
    cb = {
      on_lifecycle = function(update, current_session)
        order[#order + 1] = "lifecycle"
        observed = {
          kind = update.kind,
          status = current_session.status,
          pending = vim.tbl_count(current_session.pending_elicitations or {}),
        }
      end,
      on_update = function()
        order[#order + 1] = "foreground"
      end,
    },
  }
  local s = make({ agent = "claude-native-ui" }, "MacBook-Pro.local", cap)

  s:_on_event({
    type = "response.elicitation_request",
    json = { elicitation_id = "e1", method = "elicitation/create", params = { message = "Approve?" } },
  })

  h.eq(order, { "lifecycle", "foreground" })
  h.eq(observed.kind, "elicitation")
  h.eq(observed.pending, 1)
end

T["lifecycle fires once when the background observer owns the update"] = function()
  local lifecycle_count = 0
  local observer_count = 0
  local cap = {
    hosts = MAC,
    cb = {
      on_lifecycle = function()
        lifecycle_count = lifecycle_count + 1
      end,
    },
  }
  local s = make({ agent = "claude-native-ui" }, "MacBook-Pro.local", cap)
  s:set_observer({
    handle_update = function()
      observer_count = observer_count + 1
    end,
  })

  s:_on_event({ type = "response.created", json = { response = { id = "resp_bg" } } })

  h.eq(lifecycle_count, 1)
  h.eq(observer_count, 1)
end

T["lifecycle ignores content updates while foreground delivery continues"] = function()
  local lifecycle_count = 0
  local foreground_count = 0
  local cap = {
    hosts = MAC,
    cb = {
      on_lifecycle = function()
        lifecycle_count = lifecycle_count + 1
      end,
      on_update = function()
        foreground_count = foreground_count + 1
      end,
    },
  }
  local s = make({ agent = "claude-native-ui" }, "MacBook-Pro.local", cap)
  s.reducer.current_response_id = "resp_1"

  s:_on_event({
    type = "response.output_text.delta",
    json = { response_id = "resp_1", delta = "chunk" },
  })

  h.eq(lifecycle_count, 0)
  h.eq(foreground_count, 1)
end

T["unexpected foreground stream end emits a terminal lifecycle update"] = function()
  local updates = {}
  local ended
  local cap = {
    hosts = MAC,
    cb = {
      on_update = function() end,
      on_lifecycle = function(update)
        updates[#updates + 1] = update
      end,
      on_stream_end = function(code)
        ended = code
      end,
    },
  }
  local s = make({ agent = "claude-native-ui" }, "MacBook-Pro.local", cap)
  s.reducer.current_response_id = "resp_live"
  s._stream = {}

  s:_on_stream_done(7)

  h.eq(#updates, 1)
  h.eq(updates[1].kind, "stream_error")
  h.eq(updates[1].response_id, "resp_live")
  h.eq(updates[1].error.code, 7)
  h.eq(ended, 7)
end

T["post_message posts a well-formed message event"] = function()
  local cap = { hosts = MAC }
  local s = make({ agent = "claude-native-ui" }, "MacBook-Pro.local", cap)
  s.session_id = "conv_1"
  s:post_message("hello there")
  local body = vim.json.decode(cap.event.body)
  h.eq(body.type, "message")
  h.eq(body.data.role, "user")
  h.eq(body.data.content[1].type, "input_text")
  h.eq(body.data.content[1].text, "hello there")
end

T["interrupt posts an empty-object data payload"] = function()
  local cap = { hosts = MAC }
  local s = make({ agent = "claude-native-ui" }, "MacBook-Pro.local", cap)
  s.session_id = "conv_1"
  s:interrupt()
  -- Must be {"data":{}} (object), not [] -- the server distinguishes.
  h.is_true(cap.event.body:find('"type":"interrupt"', 1, true) ~= nil)
  h.is_true(cap.event.body:find('"data":{}', 1, true) ~= nil)
end

T["set_model patches model_override"] = function()
  local cap = { hosts = MAC }
  local s = make({ agent = "claude-native-ui" }, "MacBook-Pro.local", cap)
  s.session_id = "conv_1"
  local ok = s:set_model("claude-opus-4-8")
  h.eq(ok, true)
  h.eq(s.model_override, "claude-opus-4-8")
  h.eq(vim.json.decode(cap.patch.body).model_override, "claude-opus-4-8")
end

T["stop_stream drops the local subscription only"] = function()
  local stopped = false
  local cap = {
    hosts = MAC,
    job = function()
      return {
        stop = function()
          stopped = true
        end,
      }
    end,
  }
  local s = make({ agent = "claude-native-ui" }, "MacBook-Pro.local", cap)
  s.session_id = "conv_1"
  s:start_stream()
  h.eq(s:streaming(), true)
  s:stop_stream()
  h.eq(stopped, true)
  h.eq(s:streaming(), false)
end

-- ---- Fork (static) --------------------------------------------------------

---A request stub that records every call and answers fork/launch endpoints.
local function fork_router(cap)
  return function(o)
    cap.calls[#cap.calls + 1] = o
    if o.method == "post" and o.url:find("/fork", 1, true) then
      cap.fork = o
      return { status = 200, body = vim.json.encode(cap.fork_resp or { id = "conv_2", status = "idle" }) }
    elseif o.method == "post" and o.url:find("/runners", 1, true) then
      cap.launch = o
      if cap.launch_status and cap.launch_status >= 400 then
        return { status = cap.launch_status, body = '{"error":{"message":"boom","code":"launch_failed"}}' }
      end
      return { status = 200, body = vim.json.encode({ runner_id = "run_1", status = "starting" }) }
    end
    return { status = 404, body = "{}" }
  end
end

T["fork on a host-launched source forks then launches a worktree runner"] = function()
  local cap = { calls = {} }
  local c = client.new({ url = "http://x", request = fork_router(cap) })
  local fork, err = session.fork(c, {
    session_id = "conv_1",
    host_id = "host_mac",
    workspace = "/repo",
  }, { branch_name = "cc-fork-1" })

  h.eq(err, nil)
  h.eq(fork.id, "conv_2")
  h.is_true(cap.fork ~= nil)
  h.is_true(cap.launch ~= nil)
  local launch = vim.json.decode(cap.launch.body)
  h.eq(launch.session_id, "conv_2")
  h.eq(launch.workspace, "/repo")
  h.eq(launch.git.branch_name, "cc-fork-1")
  -- base_branch=nil => server branches from the source HEAD.
  h.eq(launch.git.base_branch, nil)
end

T["fork on a headless source does NOT launch a runner"] = function()
  local cap = { calls = {} }
  local c = client.new({ url = "http://x", request = fork_router(cap) })
  local fork, err = session.fork(c, { session_id = "conv_1" }, { branch_name = "cc-fork-1" })
  h.eq(err, nil)
  h.eq(fork.id, "conv_2")
  h.is_true(cap.fork ~= nil)
  h.eq(cap.launch, nil)
end

T["fork refuses a host source with no workspace (before launching)"] = function()
  local cap = { calls = {} }
  local c = client.new({ url = "http://x", request = fork_router(cap) })
  local fork, err = session.fork(c, { session_id = "conv_1", host_id = "host_mac" })
  h.eq(fork, nil)
  h.eq(err.code, "workspace_required")
  -- The fork was still created; only the launch is impossible.
  h.is_true(cap.fork ~= nil)
  h.eq(cap.launch, nil)
end

T["fork surfaces a launch failure carrying the unbound fork id"] = function()
  local cap = { calls = {}, launch_status = 503 }
  local c = client.new({ url = "http://x", request = fork_router(cap) })
  local fork, err = session.fork(c, {
    session_id = "conv_1",
    host_id = "host_mac",
    workspace = "/repo",
  }, { branch_name = "cc-fork-1" })
  h.eq(fork, nil)
  h.eq(err.code, "launch_failed")
  -- The caller can resume this created-but-unbound fork to retry a runner.
  h.eq(err.fork_session_id, "conv_2")
end

T["fork requires a source session id"] = function()
  local c = client.new({ url = "http://x", request = fork_router({ calls = {} }) })
  local fork, err = session.fork(c, {})
  h.eq(fork, nil)
  h.eq(err.code, "session_required")
end

---A session wired to a recording async transport, ready to compact.
local function compactable(cap)
  cap.async = cap.async or {}
  local c = client.new({
    url = "http://x",
    request = router(cap),
    job = function()
      cap.streamed = true
      return { stop = function() end }
    end,
    async_request = function(o)
      cap.async[#cap.async + 1] = o
      if cap.respond then
        o.on_complete(cap.respond)
      end
      return { stop = function() end }
    end,
  })
  local s = session.new({
    adapter = { type = "omnigent", url = "http://x", defaults = {}, opts = {} },
    client = c,
    callbacks = {},
  })
  s.session_id = "conv_1"
  return s
end

T["compact posts the control event and opens the stream"] = function()
  local cap = {}
  local s = compactable(cap)
  local accepted = s:compact({ timeout = 120000 })
  h.eq(accepted, true)

  h.eq(#cap.async, 1)
  local req = cap.async[1]
  h.eq(req.method, "post")
  h.is_true(req.url:find("/v1/sessions/conv_1/events", 1, true) ~= nil)
  h.eq(vim.json.decode(req.body).type, "compact")
  -- The per-request override wins over the client default (30s).
  h.eq(req.timeout, 120000)
  -- Without a subscription the terminal event would go unheard.
  h.eq(cap.streamed, true)
end

T["compact refuses while a turn occupies the session"] = function()
  local cap = {}
  local s = compactable(cap)
  s.status = "running"
  local accepted, err = s:compact()
  h.eq(accepted, false)
  h.is_true(err.message:find("running", 1, true) ~= nil)
  h.eq(#cap.async, 0)
end

T["compact refuses without a durable session"] = function()
  local cap = {}
  local s = compactable(cap)
  s.session_id = nil
  local accepted, err = s:compact()
  h.eq(accepted, false)
  h.is_true(err.message:find("no durable session", 1, true) ~= nil)
  h.eq(#cap.async, 0)
end

T["compact reports an HTTP rejection to its callback"] = function()
  local cap = {
    respond = {
      status = 409,
      body = vim.json.encode({
        error = { code = "conflict", message = "Cannot compact while a turn is running" },
      }),
    },
  }
  local s = compactable(cap)
  local got
  s:compact({}, function(ok, err)
    got = { ok = ok, err = err }
  end)
  h.eq(got.ok, false)
  h.eq(got.err.status, 409)
  h.is_true(got.err.message:find("Cannot compact", 1, true) ~= nil)
end

T["a turn ending settles status so busy() cannot go stale"] = function()
  -- `session.status` is its own event and can trail the terminal response event.
  -- Without this, anything gating on busy() right after a turn (compaction) sees a
  -- stale "running" and refuses.
  local cap = {}
  local s = compactable(cap)
  for _, kind in ipairs({ "turn_completed", "turn_failed", "turn_cancelled", "interrupted" }) do
    s.status = "running"
    s:_apply_state({ kind = kind })
    h.eq(s.status, "idle")
    h.eq(s:busy(), false)
  end
  -- An explicit status event still wins afterwards.
  s:_apply_state({ kind = "status", status = "running" })
  h.eq(s:busy(), true)
end

T["compaction_completed merges into usage without clobbering cost"] = function()
  local cap = {}
  local s = compactable(cap)
  s.usage = { context_tokens = 900000, total_cost_usd = 1.25, by_model = { a = 1 } }
  s:_apply_state({ kind = "compaction_completed", usage = { context_tokens = 8421 } })
  h.eq(s.usage.context_tokens, 8421)
  h.eq(s.usage.total_cost_usd, 1.25)
  h.eq(s.usage.by_model.a, 1)
end

-- ---- Async twins ----------------------------------------------------------
--
-- Each of these has a synchronous counterpart above. They exist because the sync
-- ones run on nvim's main thread: opening a chat is up to three round trips
-- (agents, hosts, create) and resuming one is two (snapshot, items), and blocking
-- on any of them freezes the editor. The pairs must stay behaviourally identical,
-- so these assert the SAME contracts -- resolved body, fail-closed refusals, error
-- precedence -- reached through the callback instead of a return value.

---A session whose async transport answers through the shared `router`, so the
---async twins are exercised against exactly the same fake server as the sync ones.
---@param defaults table
---@param hostname string
---@param cap table
local function make_async(defaults, hostname, cap)
  local route = router(cap)
  local c = client.new({
    url = "http://x",
    hostname = hostname,
    request = route,
    async_request = function(o)
      o.on_complete(route(o))
      return { stop = function() end }
    end,
    job = cap.job,
  })
  local adapter = { type = "omnigent", url = "http://x", defaults = defaults, opts = {} }
  return session.new({ adapter = adapter, client = c, callbacks = {} }), cap
end

T["create_async resolves agent/host/workspace and posts the right body"] = function()
  local cap = { hosts = MAC }
  local s = make_async({ agent = "claude-native-ui", host = "auto", workspace = "auto" }, "MacBook-Pro.local", cap)
  local got
  s:create_async(nil, function(sess, err)
    got = { sess = sess, err = err }
  end)

  h.eq(got.err, nil)
  h.eq(got.sess.id, "conv_1")
  h.eq(s.session_id, "conv_1")
  local body = vim.json.decode(cap.create.body)
  h.is_true(body.agent_id ~= nil)
  h.eq(body.host_id, "host_mac")
  h.eq(body.workspace, vim.fn.getcwd())
end

T["create_async FAILS CLOSED when host='auto' cannot resolve"] = function()
  local cap = { hosts = MAC_AND_DEVVM }
  local s = make_async({ agent = "claude-native-ui", host = "auto", workspace = "auto" }, "not-a-registered-host", cap)
  local got
  s:create_async(nil, function(sess, err)
    got = { sess = sess, err = err }
  end)
  h.eq(got.sess, nil)
  h.eq(got.err.code, "host_unresolved")
  h.eq(cap.create, nil) -- nothing was created
end

T["create_async reports an unresolvable agent before touching hosts"] = function()
  -- Error precedence matches the sync path: the fetches are chained, not raced.
  local cap = { hosts = MAC }
  local s = make_async({ agent = "no-such-agent", host = "auto", workspace = "auto" }, "MacBook-Pro.local", cap)
  local got
  s:create_async(nil, function(sess, err)
    got = { sess = sess, err = err }
  end)
  h.eq(got.sess, nil)
  h.eq(got.err.code, "agent_not_found")
end

T["load_async hydrates the snapshot and seeds the seen set"] = function()
  local cap = { hosts = MAC }
  local s = make_async({}, "MacBook-Pro.local", cap)
  local got
  s:load_async("conv_existing", function(r, err)
    got = { r = r, err = err }
  end)

  h.eq(got.err, nil)
  h.is_true(got.r.session ~= nil)
  h.is_true(#got.r.items > 0)
  h.eq(s.session_id, got.r.session.id)
  -- Seeded so a later reconnect reconcile does not re-render hydrated history.
  for _, item in ipairs(got.r.items) do
    if item.id then
      h.eq(s.seen_items[item.id], true)
    end
  end
end

T["load_async fails loudly when the items fetch fails"] = function()
  -- An empty resume must stay distinguishable from a failed one.
  local cap = { hosts = MAC }
  local route = router(cap)
  local c = client.new({
    url = "http://x",
    request = route,
    async_request = function(o)
      if o.url:find("/items", 1, true) then
        o.on_complete({ status = 503, body = '{"error":{"message":"runner gone"}}' })
        return { stop = function() end }
      end
      o.on_complete(route(o))
      return { stop = function() end }
    end,
  })
  local s = session.new({
    adapter = { type = "omnigent", url = "http://x", defaults = {}, opts = {} },
    client = c,
    callbacks = {},
  })
  local got
  s:load_async("conv_existing", function(r, err)
    got = { r = r, err = err }
  end)
  h.eq(got.r, nil)
  h.eq(got.err.status, 503)
end

---`fork_router` behind the async transport.
local function async_fork_client(cap)
  local route = fork_router(cap)
  return client.new({
    url = "http://x",
    request = route,
    async_request = function(o)
      o.on_complete(route(o))
      return { stop = function() end }
    end,
  })
end

T["fork_async on a host-launched source forks then launches a worktree runner"] = function()
  local cap = { calls = {} }
  local got
  session.fork_async(async_fork_client(cap), {
    session_id = "conv_1",
    host_id = "host_mac",
    workspace = "/repo",
  }, { branch_name = "cc-fork-1" }, function(fork, err)
    got = { fork = fork, err = err }
  end)

  h.eq(got.err, nil)
  h.eq(got.fork.id, "conv_2")
  local launch = vim.json.decode(cap.launch.body)
  h.eq(launch.session_id, "conv_2")
  h.eq(launch.workspace, "/repo")
  h.eq(launch.git.branch_name, "cc-fork-1")
  h.eq(launch.git.base_branch, nil)
end

T["fork_async on a headless source does NOT launch a runner"] = function()
  local cap = { calls = {} }
  local got
  session.fork_async(async_fork_client(cap), { session_id = "conv_1" }, nil, function(fork, err)
    got = { fork = fork, err = err }
  end)
  h.eq(got.err, nil)
  h.eq(got.fork.id, "conv_2")
  h.eq(cap.launch, nil)
end

T["fork_async surfaces a launch failure carrying the unbound fork id"] = function()
  local cap = { calls = {}, launch_status = 503 }
  local got
  session.fork_async(async_fork_client(cap), {
    session_id = "conv_1",
    host_id = "host_mac",
    workspace = "/repo",
  }, { branch_name = "cc-fork-1" }, function(fork, err)
    got = { fork = fork, err = err }
  end)
  h.eq(got.fork, nil)
  h.eq(got.err.code, "launch_failed")
  h.eq(got.err.fork_session_id, "conv_2")
end

T["fork_async requires a source session id"] = function()
  local got
  session.fork_async(async_fork_client({ calls = {} }), {}, nil, function(fork, err)
    got = { fork = fork, err = err }
  end)
  h.eq(got.fork, nil)
  h.eq(got.err.code, "session_required")
end

T["compact_via_slash_async posts /compact and opens the stream"] = function()
  local cap = {}
  local s = compactable(cap)
  local accepted, err = s:compact_via_slash_async()
  h.eq(accepted, true)
  h.eq(err, nil)

  h.eq(#cap.async, 1)
  local body = vim.json.decode(cap.async[1].body)
  h.eq(body.type, "message")
  h.eq(body.data.content[1].text, "/compact")
  h.eq(cap.streamed, true)
end

T["compact_via_slash_async refuses its preconditions SYNCHRONOUSLY"] = function()
  -- The strategy queue needs an immediate "did this one start?" answer; only the
  -- POST outcome is deferred.
  local cap = {}
  local s = compactable(cap)
  s.status = "running"
  local accepted, err = s:compact_via_slash_async()
  h.eq(accepted, false)
  h.is_true(err.message:find("running", 1, true) ~= nil)
  h.eq(#cap.async, 0)

  s.status = "idle"
  s.session_id = nil
  accepted, err = s:compact_via_slash_async()
  h.eq(accepted, false)
  h.is_true(err.message:find("no durable session", 1, true) ~= nil)
  h.eq(#cap.async, 0)
end

T["compact_via_slash_async reports an HTTP rejection to its callback"] = function()
  local cap = { respond = { status = 503, body = '{"error":{"message":"runner gone"}}' } }
  local s = compactable(cap)
  local got
  s:compact_via_slash_async(function(ok, err)
    got = { ok = ok, err = err }
  end)
  h.eq(got.ok, false)
  h.eq(got.err.status, 503)
end

T["resolve_elicitation_async posts the action to the resolve endpoint"] = function()
  local cap = {}
  local s = compactable(cap)
  local got
  s:resolve_elicitation_async("e1", { action = "accept" }, function(res, err)
    got = { res = res, err = err }
  end)

  h.eq(#cap.async, 1)
  local req = cap.async[1]
  h.eq(req.method, "post")
  h.is_true(req.url:find("/v1/sessions/conv_1/elicitations/e1/resolve", 1, true) ~= nil)
  h.eq(vim.json.decode(req.body).action, "accept")
  -- No stubbed response, so nothing came back yet: the caller was not blocked.
  h.eq(got, nil)
end

return T
