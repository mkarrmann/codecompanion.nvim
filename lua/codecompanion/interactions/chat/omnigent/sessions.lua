--=============================================================================
-- Omnigent session-list helpers (pure)
--
-- Formatting / filtering / sorting for the durable session summaries returned by
-- GET /v1/sessions (see the readonly-sessions fixture for the shape). Kept pure
-- (no I/O, injectable `now`) so both the in-chat `/omnigent_resume` picker and
-- the dotfiles resume UX can reuse it and it is unit-testable.
--=============================================================================

local M = {}

---Relative-age label for a unix timestamp (mirrors utils.make_relative but with
---an injectable `now` for deterministic tests).
---@param ts? number unix seconds
---@param now? number unix seconds (defaults to os.time())
---@return string
function M.relative(ts, now)
  if type(ts) ~= "number" then
    return "?"
  end
  now = now or os.time()
  local diff = now - ts
  if diff < 0 then
    diff = 0
  end
  if diff < 60 then
    return diff .. "s"
  elseif diff < 3600 then
    return math.floor(diff / 60) .. "m"
  elseif diff < 86400 then
    return math.floor(diff / 3600) .. "h"
  else
    return math.floor(diff / 86400) .. "d"
  end
end

---Best-effort short workspace label (leaf two path components).
---@param workspace? string
---@return string
function M.short_workspace(workspace)
  if type(workspace) ~= "string" or workspace == "" then
    return ""
  end
  local parts = {}
  for part in workspace:gmatch("[^/]+") do
    parts[#parts + 1] = part
  end
  if #parts <= 2 then
    return workspace
  end
  return ".../" .. parts[#parts - 1] .. "/" .. parts[#parts]
end

---One-line display label for a session summary.
---@param s table Session summary (id, title, agent_name, status, updated_at, workspace, pending_elicitations_count)
---@param opts? table { now?: number }
---@return string
function M.format_summary(s, opts)
  opts = opts or {}
  local parts = {}
  local age = M.relative(s.updated_at or s.created_at, opts.now)
  parts[#parts + 1] = string.format("(%s)", age)
  parts[#parts + 1] = s.title and s.title ~= "" and s.title or (s.id or "?")
  local tail = {}
  if s.agent_name and s.agent_name ~= "" then
    tail[#tail + 1] = s.agent_name
  end
  if s.status and s.status ~= "" then
    tail[#tail + 1] = s.status
  end
  local ws = M.short_workspace(s.workspace)
  if ws ~= "" then
    tail[#tail + 1] = ws
  end
  local pending = tonumber(s.pending_elicitations_count) or 0
  if pending > 0 then
    tail[#tail + 1] = pending .. "⏳"
  end
  if #tail > 0 then
    parts[#parts + 1] = "[" .. table.concat(tail, " · ") .. "]"
  end
  return table.concat(parts, " ")
end

---Filter out archived sessions.
---@param sessions table[]
---@return table[]
function M.active(sessions)
  local out = {}
  for _, s in ipairs(sessions or {}) do
    if not s.archived then
      out[#out + 1] = s
    end
  end
  return out
end

---Filter sessions whose workspace equals `cwd` (exact match).
---@param sessions table[]
---@param cwd string
---@return table[]
function M.filter_by_workspace(sessions, cwd)
  local out = {}
  for _, s in ipairs(sessions or {}) do
    if s.workspace == cwd then
      out[#out + 1] = s
    end
  end
  return out
end

---Filter sessions by a label key/value (e.g. orchest.nvim_session).
---@param sessions table[]
---@param key string
---@param value string
---@return table[]
function M.filter_by_label(sessions, key, value)
  local out = {}
  for _, s in ipairs(sessions or {}) do
    if type(s.labels) == "table" and s.labels[key] == value then
      out[#out + 1] = s
    end
  end
  return out
end

---Sort a copy of `sessions` by updated_at (then created_at) descending.
---@param sessions table[]
---@return table[]
function M.by_recency(sessions)
  local out = {}
  for _, s in ipairs(sessions or {}) do
    out[#out + 1] = s
  end
  table.sort(out, function(a, b)
    local ta = a.updated_at or a.created_at or 0
    local tb = b.updated_at or b.created_at or 0
    return ta > tb
  end)
  return out
end

return M
