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
    local name = item.name or item.tool_name or (type(item.tool) == "table" and item.tool.name) or "tool"
    return { role = C.LLM_ROLE, content = "**Tool call:** `" .. name .. "`", opts = { tool = true } }
  elseif t == "function_call_output" or t == "resource_event" then
    -- Tool output is folded under its call; resource events are terminal/setup
    -- noise. Neither becomes a standalone transcript message.
    return nil
  end

  -- Unknown durable item: keep it visible as a compact system row rather than
  -- silently dropping it.
  return { role = C.LLM_ROLE, content = M.format_unknown(t), opts = { system = true } }
end

---Map a page of durable items to an ordered list of chat messages (skips nils).
---@param items table[]
---@return table[]
function M.snapshot_messages(items)
  local out = {}
  for _, item in ipairs(items or {}) do
    local msg = M.durable_item_to_message(item)
    if msg then
      out[#out + 1] = msg
    end
  end
  return out
end

return M
