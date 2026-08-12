--=============================================================================
-- Status line for the per-tab queue UI.
--
-- Split out from the queue module so that one can stay focused on
-- submit/queue/lifecycle logic. The status line is a single scratch buffer
-- rendered into a 1-row (auto-growing) window below the input box. Content is
-- rebuilt on demand by `refresh(state)` and on a shared 1s tick managed by
-- `start(state)` / `stop(state)`.
--
-- The caller passes its own state table; the fields read here are:
--   state.status_bufnr      buffer holding the rendered lines
--   state.status_winnr      window showing that buffer
--   state.chat_bufnr        the chat being described
--   state.queue             FIFO of pending messages; count drives "Queued (N)"
--   state.queued            derived bool (#queue > 0), drives the highlight
--   state.hold_from         index of the first entry being edited, or nil
--   state.request_start_at  os.time() of the in-flight request, or nil
--
-- The 1s tick is a single shared timer: every state that called `start`
-- contributes a "wants ticking" flag, and the timer stops itself once no state
-- does.
--=============================================================================

local config = require("codecompanion.config")
local session_pin = require("codecompanion.interactions.chat.ui.session_pin")
local sessionful = require("codecompanion.interactions.chat.sessionful")
local usage = require("codecompanion.interactions.chat.usage")

local M = {}

local ns = vim.api.nvim_create_namespace("codecompanion_queue_status")

-- Set of states that want the periodic refresh. Keys are state tables.
local ticking = {}
local timer

-- ─── Highlights ──────────────────────────────────────────────────────────

local function blend(c1, c2, alpha)
  local r1, g1, b1 = math.floor(c1 / 65536) % 256, math.floor(c1 / 256) % 256, c1 % 256
  local r2, g2, b2 = math.floor(c2 / 65536) % 256, math.floor(c2 / 256) % 256, c2 % 256
  return math.floor(r1 * alpha + r2 * (1 - alpha)) * 65536
    + math.floor(g1 * alpha + g2 * (1 - alpha)) * 256
    + math.floor(b1 * alpha + b2 * (1 - alpha))
end

-- Two washes, and the distinction between them is the whole point: yellow means
-- this message goes out as things stand, grey means it does not (it is being
-- edited, or held behind one that is).
local function setup_highlights()
  local normal_hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local warn_hl = vim.api.nvim_get_hl(0, { name = "DiagnosticWarn", link = false })
  local comment_hl = vim.api.nvim_get_hl(0, { name = "Comment", link = false })

  local bg = normal_hl.bg
  if bg == nil then
    bg = vim.o.background == "light" and 0xFFFFFF or 0x1E1E2E
  end
  local warn_fg = warn_hl.fg or 0xE0A500
  local comment_fg = comment_hl.fg or 0x888888

  vim.api.nvim_set_hl(0, "CCQueuedNormal", { bg = blend(warn_fg, bg, 0.1) })
  vim.api.nvim_set_hl(0, "CCQueuedBorder", { fg = warn_fg })
  vim.api.nvim_set_hl(0, "CCHeldNormal", { bg = blend(comment_fg, bg, 0.08) })
  vim.api.nvim_set_hl(0, "CCHeldBorder", { fg = comment_fg })
end

-- ─── Segment building ────────────────────────────────────────────────────

local function fmt_tokens(n)
  if n >= 1000 then
    return string.format("%.1fk", n / 1000)
  end
  return tostring(n)
end

local function fmt_cost(cost)
  local amt = cost.amount or 0
  local sym = (cost.currency == nil or cost.currency == "USD") and "$" or (cost.currency .. " ")
  if amt < 1 then
    return string.format("%s%.3f", sym, amt)
  end
  return string.format("%s%.2f", sym, amt)
end

local function build_segments(state)
  local left, right = {}, {}
  if not state.chat_bufnr then
    return left, right
  end

  local meta = (_G.codecompanion_chat_metadata or {})[state.chat_bufnr] or {}

  local chat = require("codecompanion").buf_get_chat(state.chat_bufnr)
  local session_id = sessionful.session_id(chat)
  local session_usage = session_id and usage.get(session_id) or nil
  -- Prefer the pinned session id for display so the status bar matches the
  -- stable winbar handle and doesn't flicker on disconnect/remint. Usage is
  -- still keyed by the live id above.
  local display_session_id = session_pin.get(state.chat_bufnr) or session_id

  local qn = state.queue and #state.queue or 0
  if qn > 0 then
    left[#left + 1] = { string.format(" Queued (%d) ", qn), "DiagnosticWarn" }
    -- An entry being edited pauses the queue at that point; say so, because
    -- otherwise a queue that has silently stopped flushing looks identical to
    -- one that is merely waiting on the turn.
    if state.hold_from then
      left[#left + 1] = { string.format("⏸ %d held ", qn - state.hold_from + 1), "DiagnosticHint" }
    end
  else
    left[#left + 1] = { " Draft ", "Comment" }
  end
  left[#left + 1] = { " · ", "Comment" }
  local adapter_name = (meta.adapter and meta.adapter.name)
    or (chat and chat.adapter and (chat.adapter.name or chat.adapter.formatted_name))
    or "unknown"
  left[#left + 1] = { adapter_name, "Function" }
  if meta.adapter and meta.adapter.model then
    left[#left + 1] = { " · ", "Comment" }
    left[#left + 1] = { meta.adapter.model, "String" }
  end
  if meta.cycles and meta.cycles > 0 then
    left[#left + 1] = { " · ", "Comment" }
    left[#left + 1] = { "turn " .. meta.cycles, "Number" }
  end

  if display_session_id then
    right[#right + 1] = { display_session_id, "Constant" }
  end
  if meta.mode and meta.mode.name then
    right[#right + 1] = { meta.mode.name, "String" }
  end
  local omni_effort = meta.omnigent and meta.omnigent.reasoning_effort
  if type(omni_effort) == "string" and omni_effort ~= "" then
    right[#right + 1] = { "effort:" .. omni_effort, "DiagnosticInfo" }
  end
  if meta.tools and meta.tools > 0 then
    right[#right + 1] = { meta.tools .. " tools", "DiagnosticInfo" }
  end
  if meta.context_items and meta.context_items > 0 then
    right[#right + 1] = { meta.context_items .. " ctx", "DiagnosticInfo" }
  end
  -- Token / context-window usage. Prefer the adapter-reported chat token count
  -- (http), else per-session usage (acp/omnigent). When the window size is known
  -- fold the raw count into the "NN% used/size" segment instead of showing both.
  local used = (meta.tokens and meta.tokens > 0 and meta.tokens)
    or (session_usage and session_usage.used and session_usage.used > 0 and session_usage.used)
    or nil
  local size = (session_usage and session_usage.size and session_usage.size > 0 and session_usage.size) or nil
  if used and size then
    local pct = math.floor(100 * used / size)
    right[#right + 1] = { string.format("%d%% %s/%s", pct, fmt_tokens(used), fmt_tokens(size)), "DiagnosticInfo" }
  elseif used then
    right[#right + 1] = { fmt_tokens(used) .. " tokens", "DiagnosticInfo" }
  end
  local cost = session_usage and session_usage.cost
  if type(cost) == "table" and type(cost.amount) == "number" and cost.amount > 0 then
    right[#right + 1] = { fmt_cost(cost), "DiagnosticInfo" }
  end

  if state.request_start_at then
    local elapsed = os.time() - state.request_start_at
    local hl = "DiagnosticInfo"
    if elapsed >= 90 then
      hl = "DiagnosticError"
    elseif elapsed >= 30 then
      hl = "DiagnosticWarn"
    end
    right[#right + 1] = { string.format("%ds", elapsed), hl }
  end

  return left, right
end

local function merge_segments(left, right)
  local merged = {}
  for _, seg in ipairs(left) do
    merged[#merged + 1] = seg
  end
  for i, seg in ipairs(right) do
    if (i == 1 and #merged > 0) or i > 1 then
      merged[#merged + 1] = { " · ", "Comment" }
    end
    merged[#merged + 1] = seg
  end
  return merged
end

-- Soft-wrap merged segments into rows of at most `width` display cells.
-- Vim's 'wrap'+'linebreak' won't break inside long unbroken tokens (the session
-- id is one of them), so we do it by hand. Each row carries per-row highlight
-- spans in byte offsets.
local function pack_rows(merged, width)
  width = math.max(1, width)
  local rows = {}
  local cur_text, cur_hls, cur_width = "", {}, 0

  local function flush()
    rows[#rows + 1] = { text = cur_text, hls = cur_hls }
    cur_text, cur_hls, cur_width = "", {}, 0
  end

  for _, seg in ipairs(merged) do
    local text, hl = seg[1], seg[2]
    for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      local cw = vim.fn.strdisplaywidth(ch)
      if cur_width + cw > width and cur_width > 0 then
        flush()
      end
      local start_col = #cur_text
      cur_text = cur_text .. ch
      cur_width = cur_width + cw
      if hl then
        local last = cur_hls[#cur_hls]
        if last and last[1] == hl and last[3] == start_col then
          last[3] = start_col + #ch
        else
          cur_hls[#cur_hls + 1] = { hl, start_col, start_col + #ch }
        end
      end
    end
  end

  if cur_text ~= "" or #rows == 0 then
    flush()
  end
  return rows
end

-- ─── Public API ──────────────────────────────────────────────────────────

function M.refresh(state)
  if not state.status_bufnr or not vim.api.nvim_buf_is_valid(state.status_bufnr) then
    return
  end

  local merged = merge_segments(build_segments(state))

  local width = 80
  if state.status_winnr and vim.api.nvim_win_is_valid(state.status_winnr) then
    width = math.max(1, vim.api.nvim_win_get_width(state.status_winnr))
  end

  local rows = pack_rows(merged, width)
  local lines = {}
  for i, row in ipairs(rows) do
    lines[i] = row.text
  end

  vim.bo[state.status_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.status_bufnr, 0, -1, false, lines)
  vim.bo[state.status_bufnr].modifiable = false

  if state.status_winnr and vim.api.nvim_win_is_valid(state.status_winnr) then
    local max_rows = config.display.queue.status_max_rows
    vim.api.nvim_win_set_height(state.status_winnr, math.min(max_rows, math.max(1, #lines)))
  end

  vim.api.nvim_buf_clear_namespace(state.status_bufnr, ns, 0, -1)
  for i, row in ipairs(rows) do
    for _, h in ipairs(row.hls) do
      vim.api.nvim_buf_set_extmark(state.status_bufnr, ns, i - 1, h[2], {
        end_col = h[3],
        hl_group = h[1],
      })
    end
  end
end

-- Tint the status window while anything is queued, as the at-a-glance summary.
--
-- The input box is deliberately NOT tinted: each queued message has its own
-- window carrying its own state (see `paint_entry_labels` in the queue module),
-- and the input box holds the one thing that is *not* queued -- your next draft.
-- Colouring it on a non-empty queue said the opposite of the truth.
function M.apply_winhighlight(state)
  if state.winnr and vim.api.nvim_win_is_valid(state.winnr) then
    vim.wo[state.winnr].winhighlight = ""
  end
  if state.status_winnr and vim.api.nvim_win_is_valid(state.status_winnr) then
    vim.wo[state.status_winnr].winhighlight = state.queued and "Normal:CCQueuedNormal,WinSeparator:CCQueuedBorder" or ""
  end
end

local function stop_timer()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

local function any_ticking()
  for _ in pairs(ticking) do
    return true
  end
  return false
end

function M.start(state)
  ticking[state] = true
  if timer then
    return
  end
  timer = vim.uv.new_timer()
  timer:start(
    0,
    1000,
    vim.schedule_wrap(function()
      if not any_ticking() then
        return stop_timer()
      end
      for s in pairs(ticking) do
        M.refresh(s)
      end
    end)
  )
end

function M.stop(state)
  ticking[state] = nil
  if not any_ticking() then
    stop_timer()
  end
end

---Create a scratch buffer to render the status line into.
---@return number
function M.create_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  return buf
end

function M.setup()
  setup_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("codecompanion_queue_highlights", { clear = true }),
    callback = setup_highlights,
  })
end

return M
