local h = require("tests.helpers")
local new_set = MiniTest.new_set

local compaction = require("codecompanion.interactions.chat.omnigent.compaction")
local fs = require("tests.omnigent.fake_server")

local ADAPTER = { type = "omnigent", url = "http://x", opts = {} }

local T = new_set()

---A chat double with a compactable session stub. `session.calls` records every
---dispatched compact request; `session.refuse` makes the session-level guard fire.
local function new_chat(session_overrides, adapter)
  local chat = fs.mock_chat(adapter or ADAPTER)
  chat.omnigent_session_id = "conv_1"
  chat.omnigent_session = vim.tbl_extend("force", {
    session_id = "conv_1",
    status = "idle",
    calls = {},
    slash_calls = 0,
    busy = function(self)
      return self.status == "running" or self.status == "waiting"
    end,
    compact = function(self, opts, callback)
      self.calls[#self.calls + 1] = { opts = opts, callback = callback }
      if self.refuse then
        return false, { message = self.refuse }
      end
      return true
    end,
    compact_via_slash = function(self)
      self.slash_calls = self.slash_calls + 1
      if self.slash_refuse then
        return nil, { message = self.slash_refuse }
      end
      return { queued = true }
    end,
  }, session_overrides or {})
  return chat
end

-- Pin a single strategy so a test exercises exactly one path.
local function only(strategy)
  return { type = "omnigent", url = "http://x", opts = { compaction_strategies = { strategy } } }
end

---Capture CodeCompanionOmnigentCompaction events fired during `fn`.
local function capture_events(fn)
  local seen = {}
  local group = vim.api.nvim_create_augroup("cc_test_compaction", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeCompanionOmnigentCompaction",
    callback = function(args)
      seen[#seen + 1] = args.data
    end,
  })
  fn()
  vim.api.nvim_del_augroup_by_id(group)
  return seen
end

local function markers(chat)
  return vim.tbl_filter(function(b)
    return type(b.content) == "string" and b.content:find("Context compacted", 1, true) ~= nil
  end, chat.buf_calls)
end

T["request dispatches and marks the chat in-flight"] = function()
  local chat = new_chat()
  local events = capture_events(function()
    local ok, err = compaction.request(chat)
    h.eq(ok, true)
    h.eq(err, nil)
  end)

  h.eq(#chat.omnigent_session.calls, 1)
  h.eq(compaction.in_flight(chat), true)
  h.eq(events[1].phase, "requested")
  h.eq(events[1].session_id, "conv_1")

  compaction.cancel(chat)
end

T["request refuses without a durable session"] = function()
  local chat = new_chat()
  chat.omnigent_session = nil
  local ok, err = compaction.request(chat)
  h.eq(ok, false)
  h.is_true(err.message:find("no durable Omnigent session", 1, true) ~= nil)
  h.eq(compaction.in_flight(chat), false)
end

T["request refuses while a foreground turn is running"] = function()
  local chat = new_chat()
  chat.current_request = { cancel = function() end }
  local ok, err = compaction.request(chat)
  h.eq(ok, false)
  h.is_true(err.message:find("current request", 1, true) ~= nil)
  h.eq(#chat.omnigent_session.calls, 0)
end

T["request refuses while the session is busy with a background turn"] = function()
  local chat = new_chat({ status = "running" })
  local ok, err = compaction.request(chat)
  h.eq(ok, false)
  h.is_true(err.message:find("turn is running", 1, true) ~= nil)
  h.eq(#chat.omnigent_session.calls, 0)
end

T["request refuses a second concurrent compaction"] = function()
  local chat = new_chat()
  h.eq(compaction.request(chat), true)
  local ok, err = compaction.request(chat)
  h.eq(ok, false)
  h.is_true(err.message:find("already in progress", 1, true) ~= nil)
  -- The first request is untouched by the refusal.
  h.eq(#chat.omnigent_session.calls, 1)
  h.eq(compaction.in_flight(chat), true)

  compaction.cancel(chat)
end

T["a synchronous refusal advances to the next strategy"] = function()
  local chat = new_chat({ refuse = "no server-side compaction" })
  h.eq(compaction.request(chat), true)
  h.eq(chat.omnigent_session.slash_calls, 1)
  compaction.cancel(chat)
end

T["exhausting every strategy leaves no indicator behind"] = function()
  local chat = new_chat({
    refuse = "no server-side compaction",
    slash_refuse = "no durable session to compact",
  })
  local ok, err = compaction.request(chat)
  h.eq(ok, false)
  h.eq(err.message, "no durable session to compact")
  h.eq(compaction.in_flight(chat), false)
end

T["an HTTP rejection is terminal and leaves the transcript clean"] = function()
  -- Harnesses that declare no summarisation model are refused outright. That is a
  -- routine answer, not an event worth recording in the conversation forever.
  local chat = new_chat()
  local events = capture_events(function()
    compaction.request(chat)
    chat.omnigent_session.calls[1].callback(false, { message = "/compact is unavailable for this claude-sdk session" })
  end)

  h.eq(compaction.in_flight(chat), false)
  h.eq(events[#events].phase, "failed")
  h.eq(#markers(chat), 0)
  h.eq(#chat.buf_calls, 0)
end

T["a rejection arriving after the watchdog gave up is not re-reported"] = function()
  local chat = new_chat()
  local cb
  compaction.request(chat)
  cb = chat.omnigent_session.calls[1].callback
  compaction.cancel(chat) -- stands in for the watchdog having fired

  local events = capture_events(function()
    cb(false, { message = "too late" })
  end)
  h.eq(#events, 0)
  h.eq(#chat.buf_calls, 0)
end

T["a server-reported failure does leave a transcript note"] = function()
  local chat = new_chat()
  compaction.request(chat)
  compaction.handle_update(chat, { kind = "compaction_failed", task_id = "c1" })
  local warned = vim.tbl_filter(function(b)
    return b.content:find("Compaction failed", 1, true) ~= nil
  end, chat.buf_calls)
  h.eq(#warned, 1)
end

T["completed clears the indicator, marks the boundary and republishes usage"] = function()
  local chat = new_chat()
  local usage = {}
  local group = vim.api.nvim_create_augroup("cc_test_compaction_usage", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeCompanionOmnigentUsage",
    callback = function(args)
      usage[#usage + 1] = args.data
    end,
  })

  local events = capture_events(function()
    compaction.request(chat)
    compaction.handle_update(chat, {
      kind = "compaction_completed",
      task_id = "c1",
      total_tokens = 8421,
      usage = { context_tokens = 8421 },
    })
  end)
  vim.api.nvim_del_augroup_by_id(group)

  h.eq(compaction.in_flight(chat), false)
  h.eq(#markers(chat), 1)
  h.is_true(markers(chat)[1].content:find("8.4k tokens", 1, true) ~= nil)
  h.eq(events[#events].phase, "completed")
  h.eq(events[#events].total_tokens, 8421)
  h.eq(#usage, 1)
  h.eq(usage[1].usage.context_tokens, 8421)
end

T["a replayed completion does not stack a second marker"] = function()
  local chat = new_chat()
  local u = { kind = "compaction_completed", task_id = "c1", total_tokens = 100 }
  compaction.handle_update(chat, u)
  compaction.handle_update(chat, vim.deepcopy(u))
  h.eq(#markers(chat), 1)
end

T["failed dismisses the indicator without a boundary marker"] = function()
  local chat = new_chat()
  local events = capture_events(function()
    compaction.request(chat)
    compaction.handle_update(chat, { kind = "compaction_failed", task_id = "c1" })
  end)

  h.eq(compaction.in_flight(chat), false)
  h.eq(#markers(chat), 0)
  h.eq(events[#events].phase, "failed")
end

T["harness-driven compaction we never requested still shows progress"] = function()
  local chat = new_chat()
  -- No request(): the harness compacted itself on context overflow.
  local events = capture_events(function()
    compaction.handle_update(chat, { kind = "compaction_started", task_id = "auto" })
  end)
  h.eq(compaction.in_flight(chat), true)
  h.eq(events[#events].phase, "started")

  compaction.handle_update(chat, {
    kind = "compaction_completed",
    task_id = "auto",
    summary = "Earlier work summarised.",
  })
  h.eq(compaction.in_flight(chat), false)
  h.eq(#markers(chat), 1)
  h.is_true(markers(chat)[1].content:find("Earlier work summarised.", 1, true) ~= nil)
end

T["a late completion after cancel still renders"] = function()
  -- The watchdog (or a chat close) dropped the in-flight state; rendering must not
  -- depend on it, or a slow server would silently lose the boundary.
  local chat = new_chat()
  compaction.request(chat)
  compaction.cancel(chat)
  h.eq(compaction.in_flight(chat), false)

  compaction.handle_update(chat, { kind = "compaction_completed", task_id = "c1", total_tokens = 42 })
  h.eq(#markers(chat), 1)
end

T["a 4xx refusal falls through to the slash_command strategy"] = function()
  -- The stock SDK agents are refused server-side; the fallback is the whole point.
  local chat = new_chat()
  local events = capture_events(function()
    compaction.request(chat)
    h.eq(#chat.omnigent_session.calls, 1) -- control_event tried first
    chat.omnigent_session.calls[1].callback(false, { status = 400, message = "/compact is unavailable" })
  end)

  h.eq(chat.omnigent_session.slash_calls, 1)
  h.eq(compaction.in_flight(chat), true) -- still pending: waiting for the turn
  -- The refusal is a routing fact, not a failure the user should see.
  h.eq(#chat.buf_calls, 0)
  local phases = vim.tbl_map(function(e) return e.phase end, events)
  h.eq(phases[#phases], "requested")
  h.eq(events[#events].strategy, "slash_command")

  compaction.cancel(chat)
end

T["a 5xx is a real failure, not a fallback"] = function()
  local chat = new_chat()
  compaction.request(chat)
  chat.omnigent_session.calls[1].callback(false, { status = 500, message = "boom" })
  h.eq(chat.omnigent_session.slash_calls, 0)
  h.eq(compaction.in_flight(chat), false)
end

T["slash_command completes when the turn it created ends"] = function()
  local chat = new_chat(nil, only("slash_command"))
  local events = capture_events(function()
    h.eq(compaction.request(chat), true)
    h.eq(chat.omnigent_session.slash_calls, 1)
    h.eq(#chat.omnigent_session.calls, 0) -- control path not used
    h.eq(compaction.in_flight(chat), true)
    compaction.note_turn_end(chat)
  end)

  h.eq(compaction.in_flight(chat), false)
  h.eq(events[#events].phase, "completed")
  -- Marked as unobserved: the CLI reports nothing, so we must not claim a
  -- confirmed token count.
  h.eq(events[#events].observed, false)
  local note = vim.tbl_filter(function(b)
    return b.content:find("Compaction requested", 1, true) ~= nil
  end, chat.buf_calls)
  h.eq(#note, 1)
  h.eq(#markers(chat), 0)
end

T["note_turn_end ignores turns unrelated to compaction"] = function()
  local chat = new_chat(nil, only("control_event"))
  compaction.request(chat)
  compaction.note_turn_end(chat) -- a control_event compaction is SSE-driven
  h.eq(compaction.in_flight(chat), true)
  h.eq(#chat.buf_calls, 0)
  compaction.cancel(chat)

  local idle = new_chat()
  compaction.note_turn_end(idle) -- nothing in flight at all
  h.eq(#idle.buf_calls, 0)
end

T["adapter opts can pin the strategy order"] = function()
  local chat = new_chat(nil, only("slash_command"))
  compaction.request(chat)
  h.eq(#chat.omnigent_session.calls, 0)
  h.eq(chat.omnigent_session.slash_calls, 1)
  compaction.cancel(chat)
end

T["owns() covers exactly the compaction kinds"] = function()
  h.eq(compaction.owns("compaction_started"), true)
  h.eq(compaction.owns("compaction_completed"), true)
  h.eq(compaction.owns("compaction_failed"), true)
  h.eq(compaction.owns("turn_completed"), false)
  h.eq(compaction.owns("usage"), false)
end

return T
