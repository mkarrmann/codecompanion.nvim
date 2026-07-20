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

return T
