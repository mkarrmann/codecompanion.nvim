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
    adapter = { type = "omnigent", url = "http://x", defaults = { agent = "claude-native-ui", host = "auto", workspace = "auto" }, opts = {} },
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

return T
