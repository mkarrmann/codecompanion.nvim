local h = require("tests.helpers")
local new_set = MiniTest.new_set

local client = require("codecompanion.omnigent.client")
local session = require("codecompanion.omnigent.session")
local OmnigentHandler = require("codecompanion.interactions.chat.omnigent.handler")

-- These tests deliberately exercise error paths (which log:error). Silence that
-- logging so the suite output stays clean.
require("codecompanion.utils.log").error = function() end

local T = new_set()

local function read_raw(name)
  return table.concat(vim.fn.readfile("tests/stubs/omnigent/" .. name), "\n")
end

local MAC = { { host_id = "host_mac", name = "MacBook-Pro.local", status = "online" } }

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
      return { status = 200, body = vim.json.encode({ id = "conv_1", status = "idle" }) }
    elseif m == "get" and url:find("/items", 1, true) then
      return { status = 200, body = read_raw("items-lifecycle.json") }
    elseif m == "get" and url:find("/v1/sessions/", 1, true) then
      return { status = 200, body = read_raw("session-create.json") }
    end
    return { status = 404, body = "{}" }
  end
end

local function fake_chat(adapter, sess)
  return {
    adapter = adapter,
    messages = {},
    bufnr = 0,
    status = nil,
    omnigent_session = sess,
    MESSAGE_TYPES = {
      LLM_MESSAGE = "llm_msg",
      REASONING_MESSAGE = "reasoning_msg",
      TOOL_MESSAGE = "tool_msg",
      SYSTEM_MESSAGE = "sys_msg",
      USER_MESSAGE = "user_msg",
    },
    buf_calls = {},
    msg_calls = {},
    done_call = nil,
    current_request = nil,
    add_buf_message = function(self, msg, opts)
      table.insert(self.buf_calls, { content = msg.content, type = opts and opts.type })
    end,
    add_message = function(self, msg, opts)
      msg._meta = (opts and opts._meta) or msg._meta
      table.insert(self.messages, msg)
      table.insert(self.msg_calls, { role = msg.role, content = msg.content, meta = msg._meta })
    end,
    done = function(self, output, reasoning)
      self.done_call = { output = output, reasoning = reasoning }
      self.current_request = nil
    end,
    ready_calls = 0,
    ready_for_input = function(self)
      self.ready_calls = self.ready_calls + 1
    end,
    update_metadata = function() end,
  }
end

local ADAPTER = { type = "omnigent", url = "http://x", defaults = { agent = "claude-native-ui", host = "auto", workspace = "auto" }, opts = {} }

local function setup(cap)
  cap.hosts = cap.hosts or MAC
  cap.drive = {}
  cap.job = function(o)
    cap.drive.on_stdout = o.on_stdout
    cap.drive.on_exit = o.on_exit
    return {
      stop = function()
        cap.drive.stopped = true
      end,
    }
  end
  local c = client.new({ url = "http://x", hostname = "MacBook-Pro.local", request = router(cap), job = cap.job })
  local sess = session.new({ adapter = ADAPTER, client = c })
  local chat = fake_chat(ADAPTER, sess)
  chat.messages = { { role = "user", content = "say ok", _meta = {} } }
  return chat, OmnigentHandler.new(chat), cap
end

T["foreground turn: create -> stream -> post -> render -> complete"] = function()
  local chat, handler, cap = setup({})
  local handle = handler:submit({})

  -- Session created and message posted with only the unsent user text.
  h.eq(handle.session_id, "conv_1")
  h.is_true(cap.create ~= nil)
  h.eq(vim.json.decode(cap.event.body).data.content[1].text, "say ok")
  h.eq(chat.messages[1]._meta.sent, true)
  -- Stream was opened (before posting).
  h.is_true(cap.drive.on_stdout ~= nil)

  -- Drive the turn's events.
  cap.drive.on_stdout(read_raw("sse-clean-full.txt"))
  cap.drive.on_exit(0)

  -- Assistant deltas streamed to the buffer and accumulate to "done.".
  local streamed = table.concat(vim.tbl_map(function(b)
    return b.content
  end, vim.tbl_filter(function(b)
    return b.type == "llm_msg"
  end, chat.buf_calls)))
  h.eq(streamed, "done.")

  -- Request completed exactly once, success, with the accumulated output.
  h.eq(chat.status, "success")
  h.is_true(chat.done_call ~= nil)
  h.eq(table.concat(chat.done_call.output), "done.")
end

T["cancel posts an interrupt"] = function()
  local chat, handler, cap = setup({})
  local handle = handler:submit({})
  handle.cancel()
  h.is_true(cap.event.body:find('"type":"interrupt"', 1, true) ~= nil)
end

T["turn failure marks the request errored"] = function()
  local chat, handler, cap = setup({})
  handler:submit({})
  local failed = 'event: response.failed\n'
    .. 'data: {"type":"response.failed","response":{"id":"resp_x","error":{"message":"boom"}}}\n\n'
  cap.drive.on_stdout(failed)
  h.eq(chat.status, "error")
  h.is_true(chat.done_call ~= nil)
  local text = table.concat(vim.tbl_map(function(b)
    return b.content
  end, chat.buf_calls))
  h.is_true(text:find("boom", 1, true) ~= nil)
end

T["host resolution failure aborts the submit without creating a session"] = function()
  local cap = { hosts = { { host_id = "h", name = "some-other-box", status = "online" } } }
  cap.hosts = cap.hosts
  cap.drive = {}
  cap.job = function(o)
    cap.drive.on_stdout = o.on_stdout
    return { stop = function() end }
  end
  local c = client.new({ url = "http://x", hostname = "MacBook-Pro.local", request = router(cap), job = cap.job })
  local sess = session.new({ adapter = ADAPTER, client = c })
  local chat = fake_chat(ADAPTER, sess)
  chat.messages = { { role = "user", content = "hi", _meta = {} } }
  local handler = OmnigentHandler.new(chat)

  local handle = handler:submit({})
  h.eq(handle, nil)
  h.eq(chat.status, "error")
  h.eq(cap.create, nil) -- fail-closed: no session created
  h.is_true(chat.done_call ~= nil)
end

T["fires RequestStarted/Finished so the input queue advances"] = function()
  local chat, handler, cap = setup({})
  local events = {}
  local group = vim.api.nvim_create_augroup("omni_test_evt", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "CodeCompanionRequestStarted", "CodeCompanionRequestFinished" },
    callback = function(a)
      events[#events + 1] = { pat = a.match, data = a.data }
    end,
  })

  handler:submit({})
  cap.drive.on_stdout(read_raw("sse-clean-full.txt")) -- drives to completion
  vim.api.nvim_del_augroup_by_id(group)

  local started = vim.tbl_filter(function(e)
    return e.pat == "CodeCompanionRequestStarted"
  end, events)
  local finished = vim.tbl_filter(function(e)
    return e.pat == "CodeCompanionRequestFinished"
  end, events)
  h.eq(#started, 1)
  h.eq(#finished, 1)
  h.eq(started[1].data.bufnr, 0)
  h.eq(started[1].data.id, finished[1].data.id) -- matched pair for the queue
  h.eq(finished[1].data.status, "success")
end

T["detaches from the session on completion (no background leak)"] = function()
  local chat, handler, cap = setup({})
  handler:submit({})
  cap.drive.on_stdout(read_raw("sse-clean-full.txt")) -- drives to turn_completed
  -- The finished handler must unbind so later stream events don't render through it.
  h.eq(chat.omnigent_session.callbacks.on_update, nil)

  local before = #chat.buf_calls
  -- A stray background delta after completion must NOT render.
  cap.drive.on_stdout('event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"ghost"}\n\n')
  h.eq(#chat.buf_calls, before)
end

local function resume_setup()
  local cap = { hosts = MAC, drive = {} }
  cap.job = function(o)
    cap.drive.on_stdout = o.on_stdout
    return { stop = function() end }
  end
  local c = client.new({ url = "http://x", hostname = "MacBook-Pro.local", request = router(cap), job = cap.job })
  local sess = session.new({ adapter = ADAPTER, client = c })
  local chat = fake_chat(ADAPTER, sess)
  chat.omnigent_session_id = "conv_existing" -- resume path
  return chat, OmnigentHandler.new(chat), cap
end

T["resume() hydrates history without posting or erroring"] = function()
  local chat, handler, cap = resume_setup()
  local ok = handler:resume()
  h.eq(ok, true)

  -- items-lifecycle.json has 2 renderable durable messages (user + assistant);
  -- both hydrated into the transcript and marked sent (never re-posted).
  h.is_true(#chat.msg_calls >= 2)
  local sent = vim.tbl_filter(function(m)
    return m._meta and m._meta.sent
  end, chat.messages)
  h.is_true(#sent >= 2)

  -- Bare resume must NOT post and must NOT mark the chat errored.
  h.eq(cap.event, nil)
  h.eq(chat.status, nil)
  h.is_true(chat.ready_calls >= 1)
end

T["hydration renders user vs assistant with role-appropriate types"] = function()
  local chat, handler = resume_setup()
  handler:resume()
  local user_rows = vim.tbl_filter(function(b)
    return b.type == "user_msg"
  end, chat.buf_calls)
  local llm_rows = vim.tbl_filter(function(b)
    return b.type == "llm_msg"
  end, chat.buf_calls)
  h.is_true(#user_rows >= 1) -- the durable user message is NOT drawn as LLM output
  h.is_true(#llm_rows >= 1)
end

T["bare resume via submit() is a clean no-op, not an error"] = function()
  -- Reproduces the reported bug: opening a resumed session and submitting with no
  -- new prompt must not mark the chat errored.
  local chat, handler, cap = resume_setup()
  handler:submit({})
  h.eq(cap.event, nil) -- nothing posted
  h.eq(chat.status, nil) -- NOT "error"
  h.is_true(chat.ready_calls >= 1) -- handed back to the user
end

T["elicitation during a foreground turn is presented and does not complete"] = function()
  local chat, handler, cap = setup({})
  handler:submit({})
  local elicit = require("codecompanion.interactions.chat.omnigent.elicitation")
  local orig = elicit.handle
  local seen
  elicit.handle = function(_, _, u)
    seen = u
  end
  cap.drive.on_stdout(
    'event: response.elicitation_request\n'
      .. 'data: {"type":"response.elicitation_request","elicitation_id":"e1","method":"elicitation/create","params":{"message":"ok?"}}\n\n'
  )
  elicit.handle = orig

  h.eq(seen.elicitation_id, "e1")
  -- The turn is blocked on approval, not completed.
  h.eq(chat.done_call, nil)
  -- Pending elicitation is tracked on the session (drives update_metadata count).
  h.is_true(chat.omnigent_session.pending_elicitations ~= nil)
  h.is_true(chat.omnigent_session.pending_elicitations.e1 ~= nil)
end

T["done fires only once even if extra terminal events arrive"] = function()
  local chat, handler, cap = setup({})
  handler:submit({})
  cap.drive.on_stdout(read_raw("sse-clean-full.txt")) -- has response.completed
  local first = chat.done_call
  -- Simulate a stray second completion.
  cap.drive.on_stdout('event: response.completed\ndata: {"type":"response.completed","response":{"id":"resp_z"}}\n\n')
  h.is_true(first ~= nil)
  -- Still the same single completion (no error thrown, _done guarded).
  h.eq(chat.status, "success")
end

return T
