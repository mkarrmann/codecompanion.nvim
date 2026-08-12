--=============================================================================
-- Omnigent render helpers
--
-- Pure mapping from omnigent durable items (GET /items) to CodeCompanion chat
-- messages, used for the snapshot/resume path. Live incremental rendering during
-- a foreground turn is driven by the handler (which streams deltas straight to
-- the buffer, mirroring the ACP handler); this module owns the durable-history
-- side so both paths stay consistent.
--=============================================================================

local config = require("codecompanion.config")

local M = {}

---Concatenate the text of a message item's content blocks.
---@param item table
---@return string
function M.item_text(item)
  local parts = {}
  local content = item and item.content
  if type(content) == "table" then
    for _, c in ipairs(content) do
      if type(c) == "table" and type(c.text) == "string" then
        parts[#parts + 1] = c.text
      end
    end
  elseif type(content) == "string" then
    parts[#parts + 1] = content
  end
  return table.concat(parts, "")
end

---Does this text look like an omnigent-injected system message (sub-agent / inbox
---plumbing) rather than a real user turn? These arrive as role="user" items but
---must NOT be rendered as `## Me` sections (they pollute the input buffer and make
---`has_user_messages` true, defeating submit's "no messages" guard).
---
---Shared by both render paths: the observer (background turns) and the handler
---(a message injected into a foreground turn, i.e. steering).
---@param text any
---@return boolean
function M.is_system_injected(text)
  return type(text) == "string" and text:match("^%s*%[System:") ~= nil
end

---A `[System: ...]` injection collapsed to one quoted line.
---@param text string
---@return string
function M.system_injection_note(text)
  return "\n> _" .. vim.trim(text):gsub("%s+", " "):sub(1, 200) .. "_\n"
end

---Remember a user message this client has already written into the chat buffer.
---
---A native harness mirrors typed input back as a response output item, which
---arrives as an `item_committed` with role="user". Without this the mirror would
---render a second `## Me` for a message the client had already shown. Matching is
---by text and consumed once, because that is all the mirror carries in common
---with what we posted (ids differ, and `pending_id` is native-only).
---@param chat table
---@param ... string texts to suppress (raw and wire-transformed may differ)
function M.note_local_user_echo(chat, ...)
  if not chat then
    return
  end
  chat.omnigent_local_user_echo = chat.omnigent_local_user_echo or {}
  local seen = chat.omnigent_local_user_echo
  -- One note per DISTINCT text: the raw and wire-transformed forms are equal
  -- whenever no rewrite applied, and counting that twice would swallow a later,
  -- genuinely repeated user message.
  local noted = {}
  for _, text in ipairs({ ... }) do
    if type(text) == "string" and text ~= "" and not noted[text] then
      noted[text] = true
      seen[text] = (seen[text] or 0) + 1
    end
  end
end

---Was `text` already rendered locally? Consumes the note, so a genuinely repeated
---user message still renders the second time.
---@param chat table
---@param text any
---@return boolean
function M.consume_local_user_echo(chat, text)
  local seen = chat and chat.omnigent_local_user_echo
  if not (seen and type(text) == "string" and seen[text]) then
    return false
  end
  seen[text] = seen[text] > 1 and (seen[text] - 1) or nil
  return true
end

---Compact placeholder for a durable item type CodeCompanion doesn't render richly.
---@param item_type string
---@return string
function M.format_unknown(item_type)
  return "[Omnigent event: " .. tostring(item_type or "item") .. "]"
end

---Map a single durable item to a CodeCompanion message, or nil to skip it.
---@param item table
---@return table|nil { role, content, opts? }
function M.durable_item_to_message(item)
  if type(item) ~= "table" then
    return nil
  end
  local C = config.constants
  local t = item.type

  if t == "message" then
    local role = (item.role == "user") and C.USER_ROLE or C.LLM_ROLE
    local text = M.item_text(item)
    if text == "" then
      return nil
    end
    return { role = role, content = text }
  elseif t == "function_call" then
    return { role = C.LLM_ROLE, content = M.tool_call_line(item), opts = { tool = true }, tool_call = item }
  elseif t == "function_call_output" or t == "resource_event" then
    -- Tool output is folded under its call; resource events are terminal/setup
    -- noise. Neither becomes a standalone transcript message.
    return nil
  elseif t == "compaction" then
    -- `/items` flattens an item's `data` onto the item itself (as it does for a
    -- message's role/content), but this is the one item type we have not observed
    -- on the wire, so accept a nested `data` too rather than silently rendering an
    -- empty marker.
    local info = (type(item.data) == "table") and item.data or item
    return { role = C.LLM_ROLE, content = M.compaction_marker(info), opts = { system = true } }
  end

  -- Unknown durable item: keep it visible as a compact system row rather than
  -- silently dropping it.
  return { role = C.LLM_ROLE, content = M.format_unknown(t), opts = { system = true } }
end

---Best-effort tool name from a function_call item / update.
---@param item table
---@return string
function M.tool_name(item)
  return item.name
    or item.tool_name
    or (type(item.tool) == "table" and item.tool.name)
    or "tool"
end

local detail_keys = {
  "cmd",
  "command",
  "file_path",
  "path",
  "query",
  "pattern",
  "url",
  "prompt",
  "task",
}

local function one_line(value)
  return tostring(value or ""):gsub("\r?\n", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
end

local function shorten(value)
  local limit = 600
  if vim.fn.strchars(value) <= limit then
    return value
  end
  return vim.fn.strcharpart(value, 0, limit - 1) .. "…"
end

local function decode_arguments(item)
  local raw = item and item.arguments
  if type(raw) == "table" then
    return raw, nil
  end
  if type(raw) ~= "string" or raw == "" then
    return nil, nil
  end
  local ok, decoded = pcall(vim.json.decode, raw)
  if ok and type(decoded) == "table" then
    return decoded, raw
  end
  return nil, raw
end

local function patch_paths(value)
  if type(value) ~= "string" then
    return nil
  end
  local paths = {}
  for path in value:gmatch("%*%*%*%s+[%a ]+File:%s*([^\r\n]+)") do
    paths[#paths + 1] = vim.trim(path)
  end
  return #paths > 0 and table.concat(paths, ", ") or nil
end

---Concise detail from a function-call item's arguments.
---@param item table
---@return string|nil
function M.tool_detail(item)
  local args, raw = decode_arguments(item)
  local name = M.tool_name(item):lower()
  if name:find("apply_patch", 1, true) or name == "patch" then
    local patch = args and (args.patch or args.input) or raw
    local paths = patch_paths(patch)
    if paths then
      return shorten(paths)
    end
  end
  if args then
    for _, key in ipairs(detail_keys) do
      local value = args[key]
      if type(value) == "string" and value ~= "" then
        return shorten(one_line(value))
      end
    end
    local keys = vim.tbl_keys(args)
    table.sort(keys)
    if #keys > 0 then
      return "arguments: " .. table.concat(keys, ", ")
    end
  elseif raw then
    return shorten(one_line(raw))
  end
  return nil
end

---A compact, informative one-line marker for a live tool call.
---@param item table
---@return string
function M.tool_call_line(item)
  local detail = M.tool_detail(item)
  local suffix = detail and (" — `" .. detail:gsub("`", "'") .. "`") or ""
  return "\n> ⚙ **tool** `" .. M.tool_name(item) .. "`" .. suffix .. "\n"
end

---A compact one-line marker for a child (sub-agent) session update.
---@param u table An update with child_session_id / child
---@return string
function M.child_session_line(u)
  local c = u.child or {}
  local title = c.title or c.session_name or u.child_session_id or "sub-agent"
  local bits = {}
  if c.tool then
    bits[#bits + 1] = c.tool
  end
  local status = c.current_task_status or (c.busy and "busy") or nil
  if status then
    bits[#bits + 1] = status
  end
  local suffix = (#bits > 0) and (" (" .. table.concat(bits, " · ") .. ")") or ""
  return "\n> ↳ **sub-agent** " .. title .. suffix .. "\n"
end

---Human-readable token count for a compaction marker ("12.4k", "842").
---@param n any
---@return string|nil
local function format_tokens(n)
  if type(n) ~= "number" then
    return nil
  end
  if n < 1000 then
    return tostring(math.floor(n))
  end
  return string.format("%.1fk", n / 1000)
end

---The permanent boundary marker written where the model's context was condensed.
---
---The transcript ABOVE the marker is deliberately kept: omnigent owns the durable
---history and CodeCompanion only ever posts unsent user text (see
---OmnigentHandler:_unsent_user_text), so retaining it costs the model nothing and
---keeps the human's scrollback intact. The marker records what the model can still
---see, which is the part that actually changed.
---@param info? table { total_tokens?, summary?, summary_model?, model?, token_count? }
---@return string
function M.compaction_marker(info)
  info = type(info) == "table" and info or {}
  local bits = {}
  local tokens = format_tokens(info.total_tokens or info.token_count)
  if tokens then
    bits[#bits + 1] = tokens .. " tokens"
  end
  local model = info.summary_model or info.model
  if type(model) == "string" and model ~= "" then
    bits[#bits + 1] = "via " .. model
  end
  local suffix = (#bits > 0) and (" (" .. table.concat(bits, ", ") .. ")") or ""
  local out = "\n> [!NOTE] Context compacted" .. suffix .. "\n"
  local summary = info.summary
  if type(summary) == "string" and summary ~= "" then
    for _, line in ipairs(vim.split(vim.trim(summary), "\n", { plain = true })) do
      out = out .. "> " .. line .. "\n"
    end
  else
    out = out
      .. "> The transcript above is kept for your reference but is no longer in the\n"
      .. "> agent's context.\n"
  end
  return out
end

---A compact one-line marker for a policy denial.
---@param u table An update with reason / phase
---@return string
function M.policy_denied_line(u)
  local reason = u.reason or "denied"
  local phase = u.phase and (" [" .. u.phase .. "]") or ""
  return "\n> ⛔ **policy denied**" .. phase .. ": " .. reason .. "\n"
end

---Enrich a usage table with a context_window pulled from the session when the
---usage event omitted it (the SSE session.usage event nulls context_window).
---The session snapshot exposes the active model's window directly; fall back to
---a per-model catalog entry if the server ever populates model_options. Pure;
---returns a copy.
---@param usage any
---@param session? table
---@return table
function M.enrich_usage(usage, session)
  usage = type(usage) == "table" and vim.deepcopy(usage) or {}
  -- Explicit, offline, per-model context windows (adapter `opts.context_windows`,
  -- keyed by vendor model id) win over the server-reported window: the omnigent
  -- server falls back to a conservative catalog default when it can't reach the
  -- model catalog (e.g. a devserver with no direct internet), which mislabels the
  -- context meter. A locally-configured window for the active model is trusted.
  if session then
    local cur = session.model_override or session.model
    local configured = session.adapter and session.adapter.opts and session.adapter.opts.context_windows
    if cur and type(configured) == "table" and configured[cur] then
      usage.context_window = configured[cur]
    end
  end
  if not usage.context_window and session then
    usage.context_window = session.context_window
  end
  if not usage.context_window and session then
    local opts = session.model_options
    local cur = session.model_override or session.model
    if type(opts) == "table" and cur then
      for _, m in ipairs(opts) do
        local id = m.id or m.value or m.modelId
        if id == cur then
          usage.context_window = m.context_window or m.context_length or m.max_context
          break
        end
      end
    end
  end
  return usage
end

---Map a page of durable items to an ordered list of chat messages (skips nils).
---@param items table[]
---@return table[]
function M.snapshot_messages(items)
  local out = {}
  local calls = {}
  for _, item in ipairs(items or {}) do
    local msg = M.durable_item_to_message(item)
    if msg then
      if item.type == "function_call" then
        if item.call_id then
          calls[item.call_id] = msg
        end
      end
      out[#out + 1] = msg
    elseif item.type == "function_call_output" and item.call_id and calls[item.call_id] then
      calls[item.call_id].tool_output = item.output
    end
  end
  return out
end

return M
