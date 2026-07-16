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
  local c = client.new({
    url = "http://x",
    hostname = "MacBook-Pro.local",
    request = router(cap),
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

T["no reconnect when neither background_updates nor stream_reconnect is set"] = function()
  local s, _, jstats = setup({
    { { exit = 1 } },
    {},
  }, { adapter_opts = { background_updates = false } })
  s:start_stream()
  h.eq(jstats.calls, 1) -- dropped and stayed down
end

return T
