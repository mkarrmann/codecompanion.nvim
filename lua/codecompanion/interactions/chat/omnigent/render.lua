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
