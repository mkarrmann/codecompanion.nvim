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
  }, Reducer)
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
    updates[#updates + 1] =
      { kind = "message_delta", response_id = rid, delta = j.delta or "", text = self._text[rid] }
    return updates
  elseif t == "response.reasoning.started" then
    return { { kind = "reasoning_started", response_id = self.current_response_id } }
  elseif t == "response.reasoning_text.delta" or t == "response.reasoning_summary_text.delta" then
    local rid = self.current_response_id or "__live__"
    self._reasoning[rid] = (self._reasoning[rid] or "") .. (j.delta or "")
    return {
      {
        kind = "reasoning_delta",
        response_id = rid,
        delta = j.delta or "",
        text = self._reasoning[rid],
        summary = t == "response.reasoning_summary_text.delta",
      },
    }
  elseif t == "response.output_item.done" then
    local item = j.item or {}
    local rid = item.response_id or self.current_response_id
    local update = {
      kind = "item_committed",
      response_id = rid,
      item_id = item.id,
      item_type = item.type,
      role = item.role,
      item = item,
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
    local rid = r.id or self.current_response_id
    local u = { kind = "turn_completed", response_id = rid, model = r.model, usage = r.usage }
    close_turn(self, rid)
    self._text[rid] = nil
    self._reasoning[rid] = nil
    return { u }
  elseif t == "response.failed" then
    local r = j.response or {}
    local rid = r.id or self.current_response_id
    local u = { kind = "turn_failed", response_id = rid, error = r.error }
    close_turn(self, rid)
    return { u }
  elseif t == "response.cancelled" then
    local r = j.response or {}
    local rid = r.id or self.current_response_id
    local u = { kind = "turn_cancelled", response_id = rid }
    close_turn(self, rid)
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
    return { { kind = "status", status = j.status, response_id = j.response_id, error = j.error } }
  elseif t == "session.interrupted" then
    local rid = j.data and j.data.response_id or self.current_response_id
    close_turn(self, nil)
    return { { kind = "interrupted", response_id = rid } }
  elseif t == "session.usage" then
    return {
      {
        kind = "usage",
        usage = {
          context_tokens = j.context_tokens,
          context_window = j.context_window,
          total_cost_usd = j.total_cost_usd,
          by_model = j.usage_by_model,
        },
      },
    }
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

return M
