local h = require("tests.helpers")
local new_set = MiniTest.new_set

local sse = require("codecompanion.omnigent.sse")
local events = require("codecompanion.omnigent.events")

local T = new_set()

local function by_kind(updates, kind)
  return vim.tbl_filter(function(u)
    return u.kind == kind
  end, updates)
end

---Run a decoded-JSON-per-line (.jsonl) fixture through a fresh reducer.
local function run_jsonl(name)
  local r = events.new()
  local out = {}
  for _, line in ipairs(vim.fn.readfile("tests/stubs/omnigent/" .. name)) do
    if line ~= "" then
      local obj = vim.json.decode(line)
      vim.list_extend(out, r:handle_json(obj))
    end
  end
  return out, r
end

---Run a raw SSE fixture through the parser + a fresh reducer.
local function run_sse(name)
  local r = events.new()
  local blob = table.concat(vim.fn.readfile("tests/stubs/omnigent/" .. name), "\n")
  local p = sse.new_parser()
  local decoded = p:feed_decoded(blob)
  vim.list_extend(decoded, p:finish_decoded())
  local out = {}
  for _, ev in ipairs(decoded) do
    vim.list_extend(out, r:handle(ev))
  end
  return out, r
end

T["full lifecycle: turn open -> deltas -> commit -> complete"] = function()
  local updates, r = run_jsonl("sse-lifecycle.jsonl")

  local started = by_kind(updates, "turn_started")
  h.eq(#started, 1)
  h.eq(started[1].response_id, "resp_48ac4e4c2bca49979978588f")
  h.eq(started[1].model, "polly")
  h.eq(started[1].background, false)

  local deltas = by_kind(updates, "message_delta")
  h.is_true(#deltas >= 1)
  local committed = by_kind(updates, "item_committed")
  h.eq(#committed, 1)
  h.eq(committed[1].item_type, "message")
  -- Content-dedup invariant: accumulated delta text == the committed item text.
  h.is_true(#committed[1].text > 0)
  h.eq(deltas[#deltas].text, committed[1].text)

  local completed = by_kind(updates, "turn_completed")
  h.eq(#completed, 1)
  h.eq(completed[1].response_id, "resp_48ac4e4c2bca49979978588f")
  h.eq(type(completed[1].usage), "table")

  -- Turn boundary reached: no open response afterward.
  h.eq(r.current_response_id, nil)
end

T["input.consumed surfaces the user message"] = function()
  local updates = run_jsonl("sse-lifecycle.jsonl")
  local consumed = by_kind(updates, "input_consumed")
  h.eq(#consumed, 1)
  h.eq(consumed[1].message.content[1].text, "Reply with exactly the word: ok")
end

T["status transitions running -> idle are surfaced"] = function()
  local updates = run_jsonl("sse-lifecycle.jsonl")
  local statuses = vim.tbl_map(function(u)
    return u.status
  end, by_kind(updates, "status"))
  h.is_true(vim.tbl_contains(statuses, "running"))
  h.is_true(vim.tbl_contains(statuses, "idle"))
end

T["clean stream accumulates deltas to the committed text"] = function()
  local updates = run_sse("sse-clean-full.txt")
  local deltas = by_kind(updates, "message_delta")
  h.eq(deltas[#deltas].text, "done.")
  local committed = by_kind(updates, "item_committed")
  h.eq(committed[1].text, "done.")
end

T["child_session updates are surfaced"] = function()
  local updates = run_sse("sse-clean-full.txt")
  local kids = by_kind(updates, "child_session")
  h.eq(#kids, 2)
  h.is_true(kids[1].child_session_id ~= nil)
end

T["usage is normalised"] = function()
  local updates = run_sse("sse-clean-full.txt")
  local usage = by_kind(updates, "usage")
  h.eq(#usage, 1)
  h.eq(type(usage[1].usage.by_model), "table")
end

T["usage normalises native token and context field names"] = function()
  local r = events.new()
  local updates = r:handle({
    type = "session.usage",
    json = {
      input_tokens = 120,
      output_tokens = 30,
      context_length = 200000,
      cost_usd = 0.25,
      by_model = { codex = { input_tokens = 120, output_tokens = 30 } },
    },
  })

  h.eq(updates[1].usage.context_tokens, 150)
  h.eq(updates[1].usage.context_window, 200000)
  h.eq(updates[1].usage.total_cost_usd, 0.25)
  h.eq(type(updates[1].usage.by_model.codex), "table")
end

T["response completion usage uses the same normalised shape"] = function()
  local r = events.new()
  local updates = r:handle({
    type = "response.completed",
    json = {
      response = {
        id = "resp_native",
        usage = { prompt_tokens = 80, completion_tokens = 20, max_context = 128000 },
      },
    },
  })

  h.eq(updates[1].usage.context_tokens, 100)
  h.eq(updates[1].usage.context_window, 128000)
end

T["interrupt yields an interrupted update and clears the open turn"] = function()
  local updates, r = run_jsonl("sse-interrupt.jsonl")
  local interrupted = by_kind(updates, "interrupted")
  h.eq(#interrupted, 1)
  h.eq(r.current_response_id, nil)
  -- Confirmed contract: interrupt does NOT emit response.cancelled.
  h.eq(#by_kind(updates, "turn_cancelled"), 0)
end

T["background delta with no open turn synthesises a background turn"] = function()
  local r = events.new()
  local ev = {
    type = "response.output_text.delta",
    json = { type = "response.output_text.delta", delta = "hi", message_id = nil },
  }
  local updates = r:handle(ev)
  h.eq(updates[1].kind, "turn_started")
  h.eq(updates[1].background, true)
  h.eq(updates[2].kind, "message_delta")
  h.eq(updates[2].text, "hi")
end

T["native tool output deltas are normalised"] = function()
  local r = events.new()
  local updates = r:handle({
    type = "response.function_call_output.delta",
    json = { type = "response.function_call_output.delta", call_id = "call_1", delta = "output" },
  })
  h.eq(updates[1].kind, "tool_output_delta")
  h.eq(updates[1].call_id, "call_1")
  h.eq(updates[1].delta, "output")
end

T["native queue acknowledgement waits for the terminal-backed idle edge"] = function()
  local r = events.new()
  local started = r:handle({
    type = "response.in_progress",
    json = { type = "response.in_progress", response = { id = "resp_queue", model = "codex-native-ui" } },
  })
  h.eq(started[1].kind, "turn_started")
  local acknowledged = r:handle({
    type = "response.completed",
    json = {
      type = "response.completed",
      response = { id = "resp_queue", model = "codex-native-ui", output = {} },
    },
  })
  h.eq(#acknowledged, 0)

  local delta = r:handle({
    type = "response.output_text.delta",
    json = { type = "response.output_text.delta", message_id = "native_message", delta = "ok" },
  })
  h.eq(delta[#delta].kind, "message_delta")
  r:handle({
    type = "session.input.consumed",
    json = { type = "session.input.consumed", data = { item_id = "user_1", data = {} } },
  })
  local idle = r:handle({
    type = "session.status",
    json = { type = "session.status", status = "idle", response_id = "codex_turn" },
  })
  h.eq(idle[1].kind, "status")
  h.eq(idle[2].kind, "turn_completed")
  h.eq(idle[2].response_id, "codex_turn")
  h.eq(r.current_response_id, nil)
end

T["native idle before input consumption is not terminal"] = function()
  local r = events.new()
  r:handle({
    type = "response.in_progress",
    json = { type = "response.in_progress", response = { id = "resp_queue", model = "claude-native-ui" } },
  })
  local pre_ack_idle = r:handle({ type = "session.status", json = { type = "session.status", status = "idle" } })
  h.eq(#pre_ack_idle, 1)
  h.eq(pre_ack_idle[1].kind, "status")
  r:handle({
    type = "response.completed",
    json = { type = "response.completed", response = { id = "resp_queue", model = "claude-native-ui" } },
  })
  local early_idle = r:handle({ type = "session.status", json = { type = "session.status", status = "idle" } })
  h.eq(#early_idle, 1)
  h.eq(early_idle[1].kind, "status")

  r:handle({
    type = "session.input.consumed",
    json = { type = "session.input.consumed", data = { item_id = "user_1", data = {} } },
  })
  local committed = r:handle({
    type = "response.output_item.done",
    json = {
      type = "response.output_item.done",
      item = {
        id = "assistant_1",
        response_id = "claude_turn",
        type = "message",
        role = "assistant",
        content = { { type = "output_text", text = "ok" } },
      },
    },
  })
  h.eq(committed[1].text, "ok")
  h.eq(committed[1].text_streamed, false)
  local final_idle = r:handle({ type = "session.status", json = { type = "session.status", status = "idle" } })
  h.eq(final_idle[2].kind, "turn_completed")
end

T["native input consumption is correlated by pending id"] = function()
  local r = events.new()
  r:expect_input("pending_current")
  r:handle({
    type = "response.in_progress",
    json = { type = "response.in_progress", response = { id = "queue", model = "claude-native-ui" } },
  })
  r:handle({
    type = "response.completed",
    json = { type = "response.completed", response = { id = "queue", model = "claude-native-ui" } },
  })
  r:handle({
    type = "session.input.consumed",
    json = {
      type = "session.input.consumed",
      data = { item_id = "old", cleared_pending_id = "pending_old", data = {} },
    },
  })
  r:handle({
    type = "response.output_item.done",
    json = { type = "response.output_item.done", item = { id = "old_output", type = "message", role = "assistant" } },
  })
  local idle = r:handle({ type = "session.status", json = { type = "session.status", status = "idle" } })
  h.eq(#idle, 1)

  r:handle({
    type = "session.input.consumed",
    json = {
      type = "session.input.consumed",
      data = { item_id = "current", cleared_pending_id = "pending_current", data = {} },
    },
  })
  local waiting = r:handle({ type = "session.status", json = { type = "session.status", status = "idle" } })
  h.eq(#waiting, 1)
  r:handle({
    type = "response.output_item.done",
    json = {
      type = "response.output_item.done",
      item = { id = "current_output", type = "message", role = "assistant" },
    },
  })
  local completed = r:handle({ type = "session.status", json = { type = "session.status", status = "idle" } })
  h.eq(completed[2].kind, "turn_completed")
end

T["reopened stream (reconnect-B) replays no committed response events"] = function()
  -- The captured reconnect-B stream has zero response.* events, so a reducer
  -- fed only that stream produces no turn/message updates (the dedup crux:
  -- committed history must come from /items, not the reopened stream).
  local updates = run_sse("sse-reconnect-B.txt")
  h.eq(#by_kind(updates, "message_delta"), 0)
  h.eq(#by_kind(updates, "turn_started"), 0)
  h.eq(#by_kind(updates, "turn_completed"), 0)
end

T["ambient events (heartbeat/presence) are dropped"] = function()
  local r = events.new()
  h.eq(#r:handle({ type = "session.heartbeat", json = { type = "session.heartbeat" } }), 0)
  h.eq(#r:handle({ type = "session.presence", json = { type = "session.presence", viewers = {} } }), 0)
  -- Phantom turn.* events are ambient too.
  h.eq(#r:handle({ type = "turn.completed", json = { type = "turn.completed" } }), 0)
end

T["unknown events surface as 'other'"] = function()
  local r = events.new()
  local u = r:handle({ type = "session.brand_new_thing", json = { type = "session.brand_new_thing", x = 1 } })
  h.eq(u[1].kind, "other")
  h.eq(u[1].type, "session.brand_new_thing")
end

-- ---- Tool call / result dedup (the two-events-per-call omnigent contract) ----

---Feed one `response.output_item.done` frame.
local function item_done(r, item)
  return r:handle({ type = "response.output_item.done", json = { type = "response.output_item.done", item = item } })
end

local function open_response(r, id)
  return r:handle({
    type = "response.created",
    json = { type = "response.created", response = { id = id, model = "polly" } },
  })
end

local OBSERVED = {
  id = "fc_aaaaaaaaaaaa",
  type = "function_call",
  status = "in_progress",
  name = "sys_os_shell",
  arguments = '{"command":"ls"}',
  call_id = "toolu_vrtx_01ABC",
  response_id = "resp_1",
}
local DISPATCHED = vim.tbl_extend("force", OBSERVED, { id = "fc_bbbbbbbbbbbb", status = "completed" })

T["a tool call emitted twice is marked duplicate on the second arrival"] = function()
  local r = events.new()
  open_response(r, "resp_1")

  local first = item_done(r, OBSERVED)
  h.eq(#first, 1)
  h.eq(first[1].kind, "item_committed")
  h.eq(first[1].item_type, "function_call")
  h.eq(first[1].call_id, "toolu_vrtx_01ABC")
  h.eq(first[1].duplicate, false)

  -- Same call_id, DIFFERENT item.id -- which is exactly why item.id can't dedupe.
  local second = item_done(r, DISPATCHED)
  h.eq(#second, 1)
  h.eq(second[1].duplicate, true)
  h.is_true(second[1].item_id ~= first[1].item_id)
end

T["distinct tool calls in one response are never marked duplicate"] = function()
  local r = events.new()
  open_response(r, "resp_1")
  local a = item_done(r, vim.tbl_extend("force", OBSERVED, { call_id = "toolu_A" }))
  local b = item_done(r, vim.tbl_extend("force", OBSERVED, { call_id = "toolu_B" }))
  h.eq(a[1].duplicate, false)
  h.eq(b[1].duplicate, false)
end

T["tool call dedup resets at a response boundary (call_id reuse across turns)"] = function()
  local r = events.new()
  open_response(r, "resp_1")
  h.eq(item_done(r, OBSERVED)[1].duplicate, false)
  h.eq(item_done(r, DISPATCHED)[1].duplicate, true)

  -- A genuinely new task may reuse the same SDK-shaped call_id; it must render.
  open_response(r, "resp_2")
  h.eq(item_done(r, OBSERVED)[1].duplicate, false)
end

T["tool results dedupe per response id"] = function()
  local r = events.new()
  open_response(r, "resp_1")
  local out = {
    id = "fco_aaaaaaaaaaaa",
    type = "function_call_output",
    call_id = "toolu_vrtx_01ABC",
    output = "ok",
    response_id = "resp_1",
  }
  h.eq(item_done(r, out)[1].duplicate, false)
  -- The `response.completed` flush re-emits the same result with a new item id.
  h.eq(item_done(r, vim.tbl_extend("force", out, { id = "fco_bbbbbbbbbbbb" }))[1].duplicate, true)
end

T["a backdated result for another response is not suppressed"] = function()
  -- Rid-scoped key: a cross-turn result carrying a REUSED call_id must not eat
  -- the live turn's real result.
  local r = events.new()
  open_response(r, "resp_1")
  local out = { id = "fco_1", type = "function_call_output", call_id = "toolu_X", output = "a", response_id = "resp_1" }
  h.eq(item_done(r, out)[1].duplicate, false)
  local other = vim.tbl_extend("force", out, { id = "fco_2", response_id = "resp_other" })
  h.eq(item_done(r, other)[1].duplicate, false)
end

T["assistant message items are never flagged duplicate"] = function()
  local r = events.new()
  open_response(r, "resp_1")
  local u = item_done(r, {
    id = "msg_1",
    type = "message",
    role = "assistant",
    content = { { type = "output_text", text = "hi" } },
  })
  h.eq(u[1].duplicate, nil)
  h.eq(u[1].text, "hi")
end

T["a reconnect replay of an already-seen tool call stays deduped"] = function()
  -- reset_inflight() clears accumulated TEXT but must NOT clear the tool dedup
  -- sets, else the stream-subscribe replay re-renders every tool line.
  local r = events.new()
  open_response(r, "resp_1")
  h.eq(item_done(r, OBSERVED)[1].duplicate, false)
  r:reset_inflight()
  h.eq(item_done(r, DISPATCHED)[1].duplicate, true)
end

T["captured live stream: every tool call surfaces exactly once"] = function()
  -- Recorded off a real claude-sdk session (2026-08-06). Thirteen
  -- `function_call` frames for seven distinct calls -- the observed/dispatch
  -- pair described on Reducer:_dedupe_tool_item (six pairs, plus one call whose
  -- observed frame predates the capture). Note the interleaving: two calls open
  -- (in_progress) before either completes, which is why an un-deduped renderer
  -- draws them in the order A, B, A, B.
  local updates = run_sse("sse-tool-dedupe.txt")

  local calls, results = {}, {}
  local raw_calls = 0
  for _, u in ipairs(updates) do
    if u.kind == "item_committed" and u.item_type == "function_call" then
      raw_calls = raw_calls + 1
      if not u.duplicate then
        calls[#calls + 1] = u.call_id
      end
    elseif u.kind == "item_committed" and u.item_type == "function_call_output" then
      if not u.duplicate then
        results[#results + 1] = u.call_id
      end
    end
  end

  -- The wire really does carry nearly twice as many call frames as calls.
  h.eq(raw_calls, 13)
  h.eq(#calls, 7)

  -- Every rendered call_id is distinct.
  local seen = {}
  for _, id in ipairs(calls) do
    h.eq(seen[id], nil)
    seen[id] = true
  end

  -- Every result pairs to a rendered call and is itself rendered once.
  h.eq(#results, 7)
  local seen_results = {}
  for _, id in ipairs(results) do
    h.eq(seen[id], true)
    h.eq(seen_results[id], nil)
    seen_results[id] = true
  end
end

T["model / effort / options updates track state"] = function()
  local r = events.new()
  local m = r:handle({ type = "session.model", json = { type = "session.model", model = "claude-opus-4-8" } })
  h.eq(m[1].kind, "model")
  h.eq(m[1].model, "claude-opus-4-8")
  h.eq(r.model, "claude-opus-4-8")
  local e = r:handle({
    type = "session.reasoning_effort",
    json = { type = "session.reasoning_effort", reasoning_effort = "high" },
  })
  h.eq(e[1].reasoning_effort, "high")
  h.eq(r.reasoning_effort, "high")
end

T["compaction lifecycle reduces to its own kinds"] = function()
  local r = events.new()

  local started = r:handle_json({ type = "response.compaction.in_progress", task_id = "compact_1" })
  h.eq(#started, 1)
  h.eq(started[1].kind, "compaction_started")
  h.eq(started[1].task_id, "compact_1")

  local done = r:handle_json({
    type = "response.compaction.completed",
    task_id = "compact_1",
    total_tokens = 8421,
  })
  h.eq(#done, 1)
  h.eq(done[1].kind, "compaction_completed")
  h.eq(done[1].total_tokens, 8421)
  -- total_tokens is republished as usage so the context meter can drop at once.
  h.eq(done[1].usage.context_tokens, 8421)

  local failed = r:handle_json({ type = "response.compaction.failed", task_id = "compact_1" })
  h.eq(#failed, 1)
  h.eq(failed[1].kind, "compaction_failed")
end

T["harness-side compaction carries its summary through"] = function()
  local r = events.new()
  local done = r:handle_json({
    type = "response.compaction.completed",
    summary = "We refactored the parser.",
    summary_model = "claude-opus-4-8",
  })
  h.eq(done[1].summary, "We refactored the parser.")
  h.eq(done[1].summary_model, "claude-opus-4-8")
  -- No token count reported -> no usage update rather than a bogus zero.
  h.eq(done[1].usage, nil)
end

T["compaction does not disturb an in-flight turn"] = function()
  local r = events.new()
  r:handle_json({ type = "response.created", response = { id = "resp_1", model = "m" } })
  r:handle_json({ type = "response.output_text.delta", delta = "before " })
  r:handle_json({ type = "response.compaction.in_progress", task_id = "c1" })
  r:handle_json({ type = "response.compaction.completed", task_id = "c1", total_tokens = 10 })
  local d = r:handle_json({ type = "response.output_text.delta", delta = "after" })

  -- The turn is still open and its text accumulator survived intact.
  h.eq(r.current_response_id, "resp_1")
  h.eq(d[1].kind, "message_delta")
  h.eq(d[1].text, "before after")
end

return T
