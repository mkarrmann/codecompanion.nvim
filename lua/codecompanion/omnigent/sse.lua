--=============================================================================
-- Omnigent SSE parser
--
-- A transport-agnostic Server-Sent-Events parser for the omnigent
-- `GET /v1/sessions/{id}/stream` endpoint. It is deliberately decoupled from any
-- socket or curl job: callers feed it raw text chunks (from vim.system stdout,
-- a fixture file, or a test iterator) and it emits parsed events. It never
-- touches a buffer and holds no session state -- normalisation into
-- CodeCompanion-domain updates is the reducer's job (see events.lua).
--
-- Wire format (confirmed against captured fixtures, tests/stubs/omnigent):
--   event: response.output_text.delta
--   data: {"sequence_number": 3, "type": "response.output_text.delta", ...}
--   <blank line terminates the event>
-- The JSON payload carries its own "type" discriminator identical to the
-- `event:` field; we treat the JSON type as canonical when present.
--=============================================================================

local M = {}

---@class CodeCompanion.Omnigent.SSE.Record
---@field event? string The SSE `event:` field
---@field data? string The joined SSE `data:` field(s)
---@field id? string The SSE `id:` field
---@field retry? number The SSE `retry:` field

---@class CodeCompanion.Omnigent.SSE.Event
---@field type? string The canonical event type (JSON `type`, else `event:` field)
---@field json? table The decoded JSON payload, if the data was a JSON object
---@field raw? string The raw (undecoded) data string
---@field done boolean True for the `[DONE]` sentinel

---@class CodeCompanion.Omnigent.SSE.Parser
---@field _buf string
local Parser = {}
Parser.__index = Parser

---Parse a single SSE record (a block of lines with no blank line inside).
---@param block string
---@return CodeCompanion.Omnigent.SSE.Record
local function parse_record(block)
  local rec = {}
  local data_lines = {}
  -- Iterate lines; append a trailing newline so the final line is captured.
  for line in (block .. "\n"):gmatch("(.-)\n") do
    if line == "" or line:sub(1, 1) == ":" then
      -- Blank line inside a record shouldn't happen (records are split on
      -- blank lines) and a leading ':' is an SSE comment: ignore both.
    else
      -- `field: value` with a single optional space stripped after the colon.
      -- A line with no colon is a field name with an empty value (SSE spec).
      local field, value = line:match("^([^:]+):%s?(.*)$")
      if not field then
        field, value = line, ""
      end
      if field == "data" then
        data_lines[#data_lines + 1] = value
      elseif field == "event" then
        rec.event = value
      elseif field == "id" then
        rec.id = value
      elseif field == "retry" then
        rec.retry = tonumber(value)
      end
    end
  end
  if #data_lines > 0 then
    rec.data = table.concat(data_lines, "\n")
  end
  return rec
end

---Decode a raw SSE record into a canonical event.
---@param record CodeCompanion.Omnigent.SSE.Record
---@return CodeCompanion.Omnigent.SSE.Event
function M.decode(record)
  local raw = record.data
  if raw == nil then
    return { type = record.event, json = nil, raw = nil, done = false }
  end
  if raw == "[DONE]" then
    return { type = record.event or "done", json = nil, raw = raw, done = true }
  end
  -- Decode JSON null as absent (nil), not vim.NIL: vim.NIL is truthy, which would
  -- poison every `field or default` chain downstream (e.g. an id-less delta's
  -- `message_id: null` -> vim.NIL instead of the "__live__" fallback).
  local ok, decoded = pcall(vim.json.decode, raw, { luanil = { object = true } })
  if not ok or type(decoded) ~= "table" then
    return { type = record.event, json = nil, raw = raw, done = false }
  end
  return { type = decoded.type or record.event, json = decoded, raw = raw, done = false }
end

---Create a new incremental parser.
---@return CodeCompanion.Omnigent.SSE.Parser
function M.new_parser()
  return setmetatable({ _buf = "" }, Parser)
end

---Feed a chunk of raw stream text; returns any records completed by this chunk.
---Incomplete trailing data is buffered until the next feed/finish.
---@param chunk string|nil
---@return CodeCompanion.Omnigent.SSE.Record[]
function Parser:feed(chunk)
  local records = {}
  if chunk and chunk ~= "" then
    self._buf = self._buf .. chunk
  end
  -- Normalise line endings so the blank-line record separator is always "\n\n".
  self._buf = self._buf:gsub("\r\n", "\n"):gsub("\r", "\n")
  while true do
    local sep_start, sep_end = self._buf:find("\n\n", 1, true)
    if not sep_start then
      break
    end
    local block = self._buf:sub(1, sep_start - 1)
    self._buf = self._buf:sub(sep_end + 1)
    local rec = parse_record(block)
    if rec.event or rec.data then
      records[#records + 1] = rec
    end
  end
  return records
end

---Feed a chunk and return decoded events (feed + decode in one call).
---@param chunk string|nil
---@return CodeCompanion.Omnigent.SSE.Event[]
function Parser:feed_decoded(chunk)
  local out = {}
  for _, rec in ipairs(self:feed(chunk)) do
    out[#out + 1] = M.decode(rec)
  end
  return out
end

---Flush any buffered trailing record (a final event with no terminating blank
---line). Call once the underlying stream has closed.
---@return CodeCompanion.Omnigent.SSE.Record[]
function Parser:finish()
  local records = {}
  local block = (self._buf or ""):gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n+$", "")
  self._buf = ""
  if block ~= "" then
    local rec = parse_record(block)
    if rec.event or rec.data then
      records[#records + 1] = rec
    end
  end
  return records
end

---Flush and decode any buffered trailing record.
---@return CodeCompanion.Omnigent.SSE.Event[]
function Parser:finish_decoded()
  local out = {}
  for _, rec in ipairs(self:finish()) do
    out[#out + 1] = M.decode(rec)
  end
  return out
end

---Drive the parser from a pull-source. `source()` returns a text chunk, or nil
---when the stream ends. `on_event` is called with each decoded event. This is
---the injectable seam used by tests (source replays fixture text) and by any
---synchronous consumer; async transports should hold a parser and call
---`feed_decoded` from their read callback instead.
---@param source fun():string|nil
---@param on_event fun(event: CodeCompanion.Omnigent.SSE.Event)
---@return integer count Total events emitted
function M.run(source, on_event)
  local parser = M.new_parser()
  local count = 0
  while true do
    local chunk = source()
    if chunk == nil then
      break
    end
    for _, ev in ipairs(parser:feed_decoded(chunk)) do
      count = count + 1
      on_event(ev)
    end
  end
  for _, ev in ipairs(parser:finish_decoded()) do
    count = count + 1
    on_event(ev)
  end
  return count
end

return M
