local h = require("tests.helpers")
local new_set = MiniTest.new_set

local client = require("codecompanion.omnigent.client")
local session = require("codecompanion.omnigent.session")
local Observer = require("codecompanion.interactions.chat.omnigent.observer")
local fs = require("tests.omnigent.fake_server")

local T = new_set()

local MAC = { { host_id = "host_mac", name = "MacBook-Pro.local", status = "online" } }

-- REST router with an injectable /items body (for reconcile tests).
local function router(cap)
  return function(o)
    local url = o.url
    if url:find("/v1/hosts", 1, true) then
      return { status = 200, body = vim.json.encode({ hosts = MAC }) }
    elseif o.method == "get" and url:find("/items", 1, true) then
      return { status = 200, body = vim.json.encode({ data = cap.items or {} }) }
    elseif o.method == "get" and url:find("/v1/sessions/", 1, true) then
      return { status = 200, body = vim.json.encode({ id = "conv_1", status = "idle" }) }
    end
    return { status = 404, body = "{}" }
  end
end

-- Build a session wired to a scripted stream + a recording observer. Reconnect is
-- made synchronous via an immediate `defer` so tests are deterministic.
local function setup(connections, opts)
  opts = opts or {}
  local cap = { items = opts.items }
  local factory, jstats = fs.scripted_job(connections)
  -- One router instance behind both transports: reconcile fetches items
  -- asynchronously, so a harness that stubbed only `request` would let those
  -- calls escape to real curl. Completing inline keeps the tests deterministic,
  -- matching the immediate `defer` below.
  local route = router(cap)
  local c = client.new({
    url = "http://x",
    hostname = "MacBook-Pro.local",
    request = route,
    async_request = function(o)
      o.on_complete(route(o))
    end,
    job = factory,
  })
  local adapter = {
    type = "omnigent",
    url = "http://x",
    defaults = {},
    opts = vim.tbl_extend("force", { background_updates = true }, opts.adapter_opts or {}),
  }
  local s = session.new({
    adapter = adapter,
    client = c,
    defer = function(fn)
      fn()
    end,
  })
  s.session_id = "conv_1"
  local chat = fs.mock_chat(adapter)
  chat.omnigent_session_id = "conv_1"
  local obs = Observer.new(chat)
  s:set_observer(obs)
  return s, chat, jstats, cap
end

T["idle background turn renders through the observer"] = function()
  local s, chat = setup({
    { -- one connection, stays open
      { event = "response.output_text.delta", data = { delta = "Hello " } },
      { event = "response.output_text.delta", data = { delta = "world" } },
      { event = "response.completed", data = { response = { id = "resp_bg" } } },
    },
  })
  s:start_stream()
  h.eq(fs.rendered_text(chat, "llm_msg"), "Hello world")
  -- Committed to the transcript as a background turn.
  local committed = vim.tbl_filter(function(m)
    return m.content == "Hello world"
  end, chat.messages)
  h.eq(#committed, 1)
  h.eq(committed[1]._meta.omnigent_background, true)
end

T["reconnect after a drop replays the in-flight message without double-render"] = function()
  local s, chat, jstats = setup({
    { -- connection 1: partial then drop
      { event = "response.output_text.delta", data = { delta = "Hello" } },
      { exit = 1 },
    },
    { -- connection 2 (reconnect): server replays the whole in-flight message
      { event = "response.output_text.delta", data = { delta = "Hello world" } },
      -- stays open
    },
  })
  s:start_stream()
  -- Reconnected exactly once (2 job opens total).
  h.eq(jstats.calls, 2)
  -- Rendered "Hello" then only the new suffix " world" -- not "HelloHello world".
  h.eq(fs.rendered_text(chat, "llm_msg"), "Hello world")
end

T["stop_stream suppresses reconnect"] = function()
  local s, _, jstats = setup({
    { -- connection 1: stays open until we stop it
      { event = "response.output_text.delta", data = { delta = "hi" } },
    },
  })
  s:start_stream()
  h.eq(jstats.calls, 1)
  s:stop_stream()
  -- Simulate the job's on_exit arriving after our explicit stop.
  jstats.handles[1].stop() -- already stopped; ensure no throw
  h.eq(s:streaming(), false)
  h.eq(jstats.calls, 1) -- no reconnect
end

T["reconcile renders a turn missed during the disconnect (once)"] = function()
  -- Idle at drop (no partial). A turn completed while disconnected shows up in
  -- /items and is rendered on reconnect; a second reconnect must not re-render it.
  local s, chat, jstats = setup({
    { { exit = 1 } }, -- connection 1: immediate drop, nothing streamed
    {}, -- connection 2 (reconnect): stays open, no live events
  }, {
    items = {
      {
        id = "msg_missed",
        type = "message",
        role = "assistant",
        response_id = "resp_missed",
        content = { { type = "output_text", text = "I finished while you were away" } },
      },
    },
  })
  s:start_stream()
  h.eq(jstats.calls, 2)
  local rendered = vim.tbl_filter(function(b)
    return b.content and b.content:find("finished while you were away", 1, true) ~= nil
  end, chat.buf_calls)
  h.eq(#rendered, 1)
  -- The item is now marked seen.
  h.eq(s.seen_items["msg_missed"], true)
end

T["reconcile does not block: it renders only once the fetch completes"] = function()
  -- The regression this guards: reconcile used to fetch /items through the SYNC
  -- transport, so a reconnect against an unresponsive server froze the whole
  -- editor for the request budget. Hold the response open and assert that
  -- reconcile returned with nothing rendered -- a blocking implementation could
  -- not reach that point.
  local cap = {
    items = {
      {
        id = "msg_slow",
        type = "message",
        role = "assistant",
        response_id = "resp_slow",
        content = { { type = "output_text", text = "arrived late" } },
      },
    },
  }
  local route = router(cap)
  local pending
  local c = client.new({
    url = "http://x",
    hostname = "MacBook-Pro.local",
    request = route,
    async_request = function(o)
      -- Never completes inline: stands in for a server that accepted the
      -- connection but has not answered yet.
      pending = function()
        o.on_complete(route(o))
      end
    end,
    job = fs.scripted_job({ {} }),
  })
  local adapter = {
    type = "omnigent",
    url = "http://x",
    defaults = {},
    opts = { background_updates = true },
  }
  local s = session.new({
    adapter = adapter,
    client = c,
    defer = function(fn)
      fn()
    end,
  })
  s.session_id = "conv_1"
  local chat = fs.mock_chat(adapter)
  chat.omnigent_session_id = "conv_1"
  s:set_observer(Observer.new(chat))

  s:_reconcile()
  -- Returned while the fetch is still outstanding.
  h.eq(s._reconciling, true)
  h.eq(#chat.buf_calls, 0)

  -- A reconnect landing mid-fetch must not start a second pass.
  s:_reconcile()
  h.eq(type(pending), "function")

  pending()
  h.eq(s._reconciling, false)
  local rendered = vim.tbl_filter(function(b)
    return b.content and b.content:find("arrived late", 1, true) ~= nil
  end, chat.buf_calls)
  h.eq(#rendered, 1)
end

T["reconcile follows pagination across pages"] = function()
  -- _list_all_async chains pages via callbacks rather than a loop; a broken
  -- chain would silently render only the first page.
  local function msg(id, text)
    return { id = id, type = "message", role = "assistant", content = { { type = "output_text", text = text } } }
  end
  local pages = {
    { data = { msg("a", "page one") }, has_more = true, last_id = "a" },
    { data = { msg("b", "page two") }, has_more = false },
  }
  local seen_after = {}
  local n = 0
  local c = client.new({
    url = "http://x",
    hostname = "MacBook-Pro.local",
    request = function()
      return { status = 200, body = "{}" }
    end,
    async_request = function(o)
      n = n + 1
      -- `t[#t+1] = nil` is a no-op in Lua, so record a sentinel for "no cursor".
      seen_after[#seen_after + 1] = o.url:match("after=([^&]+)") or "<none>"
      o.on_complete({ status = 200, body = vim.json.encode(pages[n]) })
    end,
    job = fs.scripted_job({ {} }),
  })
  local adapter = {
    type = "omnigent",
    url = "http://x",
    defaults = {},
    opts = { background_updates = true },
  }
  local s = session.new({
    adapter = adapter,
    client = c,
    defer = function(fn)
      fn()
    end,
  })
  s.session_id = "conv_1"
  local chat = fs.mock_chat(adapter)
  chat.omnigent_session_id = "conv_1"
  s:set_observer(Observer.new(chat))

  s:_reconcile()
  h.eq(n, 2)
  h.eq(seen_after[1], "<none>") -- first page unpaginated
  h.eq(seen_after[2], "a") -- second page cursors off last_id
  local text = table.concat(
    vim.tbl_map(function(b)
      return b.content or ""
    end, chat.buf_calls),
    "\n"
  )
  h.eq(text:find("page one", 1, true) ~= nil, true)
  h.eq(text:find("page two", 1, true) ~= nil, true)
end

T["reconcile skips items already rendered live (seen_items)"] = function()
  -- The missed item is pre-marked seen (as if rendered live before the drop);
  -- reconcile must not render it again.
  local s, chat = setup({
    { { exit = 1 } },
    {},
  }, {
    items = {
      {
        id = "msg_seen",
        type = "message",
        role = "assistant",
        content = { { type = "output_text", text = "already shown" } },
      },
    },
  })
  s.seen_items["msg_seen"] = true
  s:start_stream()
  local rendered = vim.tbl_filter(function(b)
    return b.content and b.content:find("already shown", 1, true) ~= nil
  end, chat.buf_calls)
  h.eq(#rendered, 0)
end

-- ---- The two-events-per-tool-call contract, end to end ----------------------

---Buffer lines rendered for a tool-call marker naming `name`.
local function tool_lines(chat, name)
  return vim.tbl_filter(function(b)
    return b.content and b.content:find("`" .. name .. "`", 1, true) ~= nil
  end, chat.buf_calls)
end

T["a tool call streamed twice renders exactly one line"] = function()
  -- Omnigent emits an inline observed item (status=in_progress) and the
  -- authoritative dispatch item (status=completed) with the SAME call_id but
  -- DIFFERENT item ids. Clients must keep the first.
  local s, chat = setup({
    {
      { event = "response.created", data = { response = { id = "resp_1", model = "polly" } } },
      {
        event = "response.output_item.done",
        data = {
          item = {
            id = "fc_observed",
            type = "function_call",
            status = "in_progress",
            name = "sys_os_shell",
            arguments = '{"command":"sl status"}',
            call_id = "toolu_1",
          },
        },
      },
      {
        event = "response.output_item.done",
        data = {
          item = {
            id = "fc_dispatched",
            type = "function_call",
            status = "completed",
            name = "sys_os_shell",
            arguments = '{"command":"sl status"}',
            call_id = "toolu_1",
          },
        },
      },
    },
  })
  s:start_stream()
  h.eq(#tool_lines(chat, "sys_os_shell"), 1)
  -- Both arrivals still register the call so a reconcile can't replay it.
  h.eq(s.seen_calls["toolu_1"], true)
end

T["reconcile skips a tool call already rendered live (call_id, not item id)"] = function()
  -- The store id (32-hex) NEVER matches the stream's `fc_<uuid>`, so an
  -- item-id-keyed filter replays every tool call on reconnect. call_id is the
  -- only correlator shared by both namespaces.
  local s, chat = setup({
    {
      { event = "response.created", data = { response = { id = "resp_1", model = "polly" } } },
      {
        event = "response.output_item.done",
        data = {
          item = {
            id = "fc_stream_id",
            type = "function_call",
            name = "sys_os_shell",
            arguments = '{"command":"sl log"}',
            call_id = "toolu_2",
          },
        },
      },
      { exit = 1 },
    },
    {},
  }, {
    items = {
      {
        id = "4eba329a0ea5462e83f8493bde2417ee", -- durable store id, unrelated to fc_stream_id
        type = "function_call",
        name = "sys_os_shell",
        arguments = '{"command":"sl log"}',
        call_id = "toolu_2",
      },
    },
  })
  s:start_stream()
  h.eq(#tool_lines(chat, "sys_os_shell"), 1)
end

T["reconcile skips a user message already delivered via input.consumed"] = function()
  -- `session.input.consumed` is the only stream event carrying a user item's
  -- durable id; without folding it in, every reconcile replays the prompt.
  local s, chat = setup({
    {
      {
        event = "session.input.consumed",
        data = { data = { item_id = "731ba88ac7f543958fc589c972f25069", type = "message" } },
      },
      { exit = 1 },
    },
    {},
  }, {
    items = {
      {
        id = "731ba88ac7f543958fc589c972f25069",
        type = "message",
        role = "user",
        content = { { type = "input_text", text = "Explain my commit stack" } },
      },
    },
  })
  s:start_stream()
  local replayed = vim.tbl_filter(function(b)
    return b.content and b.content:find("Explain my commit stack", 1, true) ~= nil
  end, chat.buf_calls)
  h.eq(#replayed, 0)
end

T["an empty reconcile batch does not append a second input anchor"] = function()
  -- The common case: a heartbeat-forced reconnect on an idle session missed
  -- nothing. Restoring the anchor then orphans the `## Me` chat:done left.
  local s, chat = setup({
    { { exit = 1 } },
    {},
  }, {
    items = {
      { id = "seen_1", type = "message", role = "assistant", content = { { type = "output_text", text = "old" } } },
    },
  })
  s.seen_items["seen_1"] = true
  s:start_stream()
  h.eq(chat.input_anchor_resets, 0)
end

T["a non-empty reconcile batch still restores the input anchor"] = function()
  local s, chat = setup({
    { { exit = 1 } },
    {},
  }, {
    items = {
      { id = "missed_1", type = "message", role = "assistant", content = { { type = "output_text", text = "new" } } },
    },
  })
  s:start_stream()
  h.eq(chat.input_anchor_resets, 1)
end

T["no reconnect when neither background_updates nor stream_reconnect is set"] = function()
  local s, _, jstats = setup({
    { { exit = 1 } },
    {},
  }, { adapter_opts = { background_updates = false } })
  s:start_stream()
  h.eq(jstats.calls, 1) -- dropped and stayed down
end

return T
