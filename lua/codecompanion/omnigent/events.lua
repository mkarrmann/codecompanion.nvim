--=============================================================================
-- Omnigent event reducer
--
-- Normalises raw omnigent SSE events (see sse.lua) into a small, stable set of
-- CodeCompanion-domain updates. It is stateful by necessity: the deployed
-- harness streams assistant text as id-less `response.output_text.delta` events,
-- so the reducer anchors a per-turn text accumulator on the `current_response_id`
-- it learns from the lifecycle events (`response.created`/`in_progress`), and
-- synthesises a (background) turn start if a delta arrives with no open turn --
-- the case that happens on reconnect replay and on externally-triggered wakeups.
--
-- Design notes baked in from the empirical contract (tests/stubs/omnigent):
--  * deltas carry no ids -> content accumulation, not id dedup, is authoritative;
--  * `session.interrupted` (not `response.cancelled`) ends an interrupted turn;
--  * `turn.*` events are never emitted in a normal turn -> treated as ambient;
--  * reasoning text is transient and is never reconciled across reconnect.
--
-- handle() returns a LIST of updates (0..n) so a single wire event can expand
-- (e.g. a background delta -> [turn_started, message_delta]). Each update:
--   { kind = <string>, response_id? = string, item_id? = string, ... }
--=============================================================================

local M = {}

---@class CodeCompanion.Omnigent.Update
---@field kind string
---@field response_id? string
---@field item_id? string
---@field [string] any

---@class CodeCompanion.Omnigent.Reducer
---@field current_response_id? string
---@field model? string
---@field reasoning_effort? string
---@field _text table<string,string> Accumulated assistant text per response id
---@field _reasoning table<string,string> Accumulated (transient) reasoning per response id
---@field _native_pending boolean A terminal-backed input is still running after its queue acknowledgement
---@field _native_input_consumed boolean The terminal-backed runner consumed the queued input
---@field _native_turn_started boolean The terminal-backed runner began producing the real turn
---@field _native_queue_response boolean The open response belongs to native input delivery, not model output
---@field _message_delta_seen boolean The current logical turn emitted assistant text deltas
---@field _expected_pending_id? string Pending input owned by the foreground CodeCompanion request
local Reducer = {}
Reducer.__index = Reducer

-- Events with no CodeCompanion-domain meaning for the chat transcript. Includes
-- the phantom `turn.*` lifecycle (never emitted in a real turn per the captured
-- fixtures) and `response.incomplete` (dropped per the corrected contract).
local AMBIENT = {
  ["session.heartbeat"] = true,
  ["response.heartbeat"] = true,
  ["session.presence"] = true,
  ["session.resource.created"] = true,
  ["session.resource.deleted"] = true,
  ["session.changed_files.invalidated"] = true,
  ["session.sandbox_status"] = true,
  ["session.terminal.activity"] = true,
  ["session.todos"] = true,
  ["session.skills"] = true,
  ["session.mcp_startup"] = true,
  ["session.superseded"] = true,
  ["session.agent_changed"] = true,
  ["session.collaboration_mode"] = true,
  ["turn.started"] = true,
  ["turn.completed"] = true,
  ["turn.failed"] = true,
  ["turn.cancelled"] = true,
  ["response.queued"] = true,
  ["response.retry"] = true,
  ["response.incomplete"] = true,
}

---@return CodeCompanion.Omnigent.Reducer
function M.new()
  return setmetatable({
    current_response_id = nil,
    model = nil,
    reasoning_effort = nil,
    _text = {},
    _reasoning = {},
    _native_pending = false,
    _native_input_consumed = false,
    _native_turn_started = false,
    _native_queue_response = false,
    _message_delta_seen = false,
    _expected_pending_id = nil,
  }, Reducer)
end

---Correlate the next consumed native input with the POST response.
---@param pending_id? string
function Reducer:expect_input(pending_id)
  self._expected_pending_id = pending_id
end

---Extract the plain text of an assistant message item's content blocks.
---@param item table
---@return string
local function item_text(item)
  local parts = {}
  local content = item and item.content
  if type(content) == "table" then
    for _, c in ipairs(content) do
      if type(c) == "table" and type(c.text) == "string" then
        parts[#parts + 1] = c.text
      end
    end
  end
  return table.concat(parts, "")
end

---Normalise a raw usage table to the shape the UI consumes:
---`{ context_tokens, context_window, total_cost_usd, by_model }`. The field
---spelling depends on the underlying harness: the claude-sdk harness reports
---`context_tokens`/`context_window` (session.usage), whereas the codex
---app-server surfaces token counts under input/output/total keys on the
---response object. Map the common spellings so a token count is captured
---regardless of harness. Unknown fields stay nil (dropped, not zeroed) so a
---missing value is distinguishable from a real zero downstream.
---@param u any
---@return table|nil
local function normalize_usage(u)
  if type(u) ~= "table" then
    return nil
  end
  local ctx = u.context_tokens or u.total_tokens or u.tokens
  if not ctx then
    local inp = u.input_tokens or u.prompt_tokens
    local out = u.output_tokens or u.completion_tokens
    if inp or out then
      ctx = (inp or 0) + (out or 0)
    end
  end
  return {
    context_tokens = ctx,
    context_window = u.context_window or u.context_length or u.max_context or u.window_size,
    total_cost_usd = u.total_cost_usd or u.cost_usd,
    by_model = u.usage_by_model or u.by_model,
  }
end

---Open a turn for `rid` if none is open, returning a turn_started update or nil.
---@param self CodeCompanion.Omnigent.Reducer
---@param rid string
---@param model? string
---@param background boolean
---@return CodeCompanion.Omnigent.Update|nil
local function open_turn(self, rid, model, background)
  if self.current_response_id == rid then
    return nil
  end
  self.current_response_id = rid
  if model then
    self.model = model
  end
  self._text[rid] = self._text[rid] or ""
  self._message_delta_seen = false
  return { kind = "turn_started", response_id = rid, model = model or self.model, background = background }
end

---Close the current turn if it matches `rid`.
---@param self CodeCompanion.Omnigent.Reducer
---@param rid? string
local function close_turn(self, rid)
  if rid and self.current_response_id == rid then
    self.current_response_id = nil
  elseif not rid then
    self.current_response_id = nil
  end
end

---Clear terminal-backed turn correlation state.
---@param self CodeCompanion.Omnigent.Reducer
local function reset_native(self)
  self._native_pending = false
  self._native_input_consumed = false
  self._native_turn_started = false
  self._native_queue_response = false
  self._message_delta_seen = false
  self._expected_pending_id = nil
end

---Normalise a decoded SSE event into zero or more updates.
---@param event CodeCompanion.Omnigent.SSE.Event  A decoded event ({type, json, ...})
---@return CodeCompanion.Omnigent.Update[]
function Reducer:handle(event)
  local t = event and event.type
  local j = event and event.json
  if not t then
    return {}
  end
  if AMBIENT[t] then
    return {}
  end
  if type(j) ~= "table" then
    -- e.g. the [DONE] sentinel or non-JSON payload.
    if event.done then
      return { { kind = "done" } }
    end
    return {}
  end

  -- ----- Response lifecycle (id/model bearing) -----------------------------
  if t == "response.created" or t == "response.in_progress" then
    local r = j.response or {}
    self._native_queue_response = type(r.model) == "string" and r.model:match("%-native%-ui$") ~= nil
    local u = open_turn(self, r.id, r.model, false)
    return u and { u } or {}
  elseif t == "response.output_text.delta" then
    local rid = self.current_response_id
    local updates = {}
    if not rid then
      -- Background/reconnect delta with no preceding lifecycle event: open a
      -- fresh (background) turn keyed on the message id if present, else a
      -- synthetic marker. This is the wakeup / passive-stream case.
      rid = j.message_id or "__live__"
      local started = open_turn(self, rid, nil, true)
      if started then
        updates[#updates + 1] = started
      end
    end
    self._text[rid] = (self._text[rid] or "") .. (j.delta or "")
    self._message_delta_seen = true
    if self._native_pending then
      self._native_turn_started = true
    end
    updates[#updates + 1] =
      { kind = "message_delta", response_id = rid, delta = j.delta or "", text = self._text[rid] }
    return updates
  elseif t == "response.reasoning.started" then
    return { { kind = "reasoning_started", response_id = self.current_response_id } }
  elseif t == "response.reasoning_text.delta" or t == "response.reasoning_summary_text.delta" then
    local rid = self.current_response_id or "__live__"
    self._reasoning[rid] = (self._reasoning[rid] or "") .. (j.delta or "")
    if self._native_pending then
      self._native_turn_started = true
    end
    return {
      {
        kind = "reasoning_delta",
        response_id = rid,
        delta = j.delta or "",
        text = self._reasoning[rid],
        summary = t == "response.reasoning_summary_text.delta",
      },
    }
  elseif t == "response.function_call_output.delta" then
    if self._native_pending then
      self._native_turn_started = true
    end
    return {
      {
        kind = "tool_output_delta",
        response_id = self.current_response_id,
        call_id = j.call_id,
        delta = j.delta or "",
      },
    }
  elseif t == "response.output_item.done" then
    local item = j.item or {}
    if self._native_pending then
      self._native_turn_started = true
    end
    local rid = item.response_id or self.current_response_id
    local update = {
      kind = "item_committed",
      response_id = rid,
      item_id = item.id,
      item_type = item.type,
      role = item.role,
      item = item,
      text_streamed = self._message_delta_seen,
    }
    if item.type == "message" then
      update.text = item_text(item)
    end
    if item.call_id then
      update.call_id = item.call_id
    end
    return { update }
  elseif t == "response.completed" then
    local r = j.response or {}
    if type(r.model) == "string" and r.model:match("%-native%-ui$") and r.usage == nil then
      self._native_pending = true
      self._native_input_consumed = false
      self._native_turn_started = false
      self._native_queue_response = false
      close_turn(self, r.id)
      return {}
    end
    local rid = r.id or self.current_response_id
    local u = { kind = "turn_completed", response_id = rid, model = r.model, usage = normalize_usage(r.usage) }
    close_turn(self, rid)
    self._text[rid] = nil
    self._reasoning[rid] = nil
    return { u }
  elseif t == "response.failed" then
    local r = j.response or {}
    local rid = r.id or self.current_response_id
    local u = { kind = "turn_failed", response_id = rid, error = r.error }
    close_turn(self, rid)
    reset_native(self)
    return { u }
  elseif t == "response.cancelled" then
    local r = j.response or {}
    local rid = r.id or self.current_response_id
    local u = { kind = "turn_cancelled", response_id = rid }
    close_turn(self, rid)
    reset_native(self)
    return { u }
  elseif t == "response.error" then
    return {
      {
        kind = "error",
        response_id = self.current_response_id,
        source = j.source,
        tool_name = j.tool_name,
        error = j.error,
      },
    }
  elseif t == "response.elicitation_request" then
    return {
      { kind = "elicitation", elicitation_id = j.elicitation_id, method = j.method, params = j.params },
    }
  elseif t == "response.elicitation_resolved" then
    return { { kind = "elicitation_resolved", elicitation_id = j.elicitation_id } }
  elseif t == "response.policy_denied" then
    return { { kind = "policy_denied", reason = j.reason, phase = j.phase } }
  end

  -- ----- Session-level -----------------------------------------------------
  if t == "session.status" then
    local status = { kind = "status", status = j.status, response_id = j.response_id, error = j.error }
    if
      j.status == "idle"
      and (
        (self._native_pending and self._native_input_consumed and self._native_turn_started)
        or (self.current_response_id and not self._native_queue_response)
      )
    then
      local rid = j.response_id or self.current_response_id
      local current = self.current_response_id
      close_turn(self, nil)
      self._message_delta_seen = false
      reset_native(self)
      if current then
        self._text[current] = nil
        self._reasoning[current] = nil
      end
      return { status, { kind = "turn_completed", response_id = rid, native = true } }
    end
    if j.status == "running" and self._native_pending and self._native_input_consumed and j.response_id then
      self._native_turn_started = true
    end
    return { status }
  elseif t == "session.interrupted" then
    local rid = j.data and j.data.response_id or self.current_response_id
    close_turn(self, nil)
    reset_native(self)
    return { { kind = "interrupted", response_id = rid } }
  elseif t == "session.usage" then
    return { { kind = "usage", usage = normalize_usage(j) } }
  elseif t == "session.model" then
    self.model = j.model
    return { { kind = "model", model = j.model } }
  elseif t == "session.reasoning_effort" then
    self.reasoning_effort = j.reasoning_effort
    return { { kind = "model", reasoning_effort = j.reasoning_effort } }
  elseif t == "session.model_options" then
    return { { kind = "model", model_options = j.model_options or j.options or j.models } }
  elseif t == "session.input.consumed" then
    local d = j.data or {}
    local matches_expected = not self._expected_pending_id or d.cleared_pending_id == self._expected_pending_id
    if self._native_pending and matches_expected then
      self._native_input_consumed = true
      self._native_turn_started = false
      self._expected_pending_id = nil
    end
    return { { kind = "input_consumed", item_id = d.item_id, message = d.data } }
  elseif t == "session.child_session.updated" then
    return { { kind = "child_session", child_session_id = j.child_session_id, child = j.child } }
  elseif t == "session.created" then
    return {
      {
        kind = "child_session_created",
        child_session_id = j.child_session_id,
        agent_id = j.agent_id,
        parent_session_id = j.parent_session_id,
      },
    }
  end

  -- Unknown: surface it so the renderer can show a compact row rather than
  -- silently dropping something that might matter.
  return { { kind = "other", type = t, data = j } }
end

---Convenience for feeding a raw decoded JSON event object (as stored one-per-line
---in the *.jsonl fixtures) without the SSE wrapper.
---@param json table
---@return CodeCompanion.Omnigent.Update[]
function Reducer:handle_json(json)
  return self:handle({ type = json and json.type, json = json })
end

---The accumulated in-flight assistant text for a response id (or the current one).
---@param response_id? string
---@return string
function Reducer:live_text(response_id)
  return self._text[response_id or self.current_response_id or ""] or ""
end

---Reset the in-flight accumulator for the current response so a reconnect replay
---rebuilds it from scratch (the server replays the whole in-flight message on
---/stream subscribe; without this the reducer would double-append it to the
---pre-drop total). The response id is kept so replayed deltas keep the same key --
---the observer then appends only the new suffix beyond what it already rendered.
function Reducer:reset_inflight()
  local rid = self.current_response_id
  if rid then
    self._text[rid] = ""
    self._reasoning[rid] = ""
  end
end

return M
