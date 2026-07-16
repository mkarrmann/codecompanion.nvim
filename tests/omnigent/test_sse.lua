local h = require("tests.helpers")
local new_set = MiniTest.new_set

local sse = require("codecompanion.omnigent.sse")

local T = new_set()

---Read a fixture file into a single string (LF line endings).
local function fixture(name)
  return table.concat(vim.fn.readfile("tests/stubs/omnigent/" .. name), "\n")
end

---Count events by type.
local function type_counts(events)
  local c = {}
  for _, e in ipairs(events) do
    c[e.type] = (c[e.type] or 0) + 1
  end
  return c
end

---Parse a whole blob (feed + finish) into decoded events.
local function parse_all(blob)
  local p = sse.new_parser()
  local events = p:feed_decoded(blob)
  vim.list_extend(events, p:finish_decoded())
  return events
end

T["parses the full clean stream fixture"] = function()
  local events = parse_all(fixture("sse-clean-full.txt"))
  h.eq(#events, 13)

  local c = type_counts(events)
  h.eq(c["response.output_text.delta"], 2)
  h.eq(c["response.output_item.done"], 1)
  h.eq(c["response.completed"], 1)
  h.eq(c["session.child_session.updated"], 2)
  h.eq(c["session.heartbeat"], 2)
  h.eq(c["session.status"], 1)
  h.eq(c["session.usage"], 1)
end

T["assistant text deltas decode with their delta payloads"] = function()
  local events = parse_all(fixture("sse-clean-full.txt"))
  local deltas = vim.tbl_filter(function(e)
    return e.type == "response.output_text.delta"
  end, events)
  h.eq(#deltas, 2)
  h.eq(deltas[1].json.delta, "done")
  h.eq(deltas[2].json.delta, ".")
  -- Confirmed contract: deltas carry no ids (content-dedup is required).
  h.eq(deltas[1].json.message_id, vim.NIL)
  h.eq(deltas[1].json.index, vim.NIL)
end

T["output_item.done carries the durable committed item"] = function()
  local events = parse_all(fixture("sse-clean-full.txt"))
  local done = vim.tbl_filter(function(e)
    return e.type == "response.output_item.done"
  end, events)[1]
  h.eq(done.json.item.type, "message")
  h.eq(done.json.item.role, "assistant")
  h.eq(done.json.item.content[1].text, "done.")
  h.is_true(done.json.item.id ~= nil)
end

T["chunk-split feeding yields identical events"] = function()
  local blob = fixture("sse-clean-full.txt")
  local whole = parse_all(blob)

  -- Feed the same bytes 7 at a time; result must match feeding it whole.
  local p = sse.new_parser()
  local split = {}
  for i = 1, #blob, 7 do
    vim.list_extend(split, p:feed_decoded(blob:sub(i, i + 6)))
  end
  vim.list_extend(split, p:finish_decoded())

  h.eq(#split, #whole)
  for i = 1, #whole do
    h.eq(split[i].type, whole[i].type)
  end
end

T["handles CRLF line endings"] = function()
  local blob = "event: session.status\r\n"
    .. 'data: {"type": "session.status", "status": "idle"}\r\n\r\n'
  local events = parse_all(blob)
  h.eq(#events, 1)
  h.eq(events[1].type, "session.status")
  h.eq(events[1].json.status, "idle")
end

T["joins multiple data lines and ignores comments"] = function()
  local blob = ":this is a comment\ndata: line1\ndata: line2\n\n"
  local p = sse.new_parser()
  local records = p:feed(blob)
  h.eq(#records, 1)
  h.eq(records[1].data, "line1\nline2")
end

T["recognises the [DONE] sentinel"] = function()
  local events = parse_all("data: [DONE]\n\n")
  h.eq(#events, 1)
  h.eq(events[1].done, true)
end

T["prefers the JSON type over the event field"] = function()
  -- event: field and JSON type identical in practice; JSON type is canonical.
  local blob = 'event: wrong\ndata: {"type": "response.completed"}\n\n'
  local events = parse_all(blob)
  h.eq(events[1].type, "response.completed")
end

T["run() drives from a pull-source"] = function()
  local blob = fixture("sse-clean-full.txt")
  -- Emit the blob in three slices, then nil to end.
  local slices = { blob:sub(1, 100), blob:sub(101, 500), blob:sub(501) }
  local i = 0
  local collected = {}
  local n = sse.run(function()
    i = i + 1
    return slices[i]
  end, function(ev)
    collected[#collected + 1] = ev
  end)
  h.eq(n, 13)
  h.eq(#collected, 13)
end

T["non-JSON data survives as raw"] = function()
  local events = parse_all("event: session.heartbeat\ndata: not-json\n\n")
  h.eq(events[1].type, "session.heartbeat")
  h.eq(events[1].json, nil)
  h.eq(events[1].raw, "not-json")
end

return T
