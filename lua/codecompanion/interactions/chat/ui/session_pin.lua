--=============================================================================
-- Stable, pinned durable-session id for a chat, rendered in the chat winbar.
--
-- The live session id is volatile: an ACP connection nils it when the agent
-- process exits and silently re-mints one on the next turn, and resume/fork
-- mint fresh ids outright. Anything that displays the live value therefore
-- changes out from under the user on every disconnect, which makes it useless
-- as a handle to quote.
--
-- This module pins the FIRST session id established for a chat buffer and never
-- overwrites it for that buffer's life. The pin is reset only when the
-- transcript itself is torn down or replaced -- chat close, or an in-place
-- adapter swap -- because a deliberate resume/fork opens a NEW chat buffer,
-- which naturally pins to its loaded session on first establish.
--
-- Involuntary re-minting is not hidden, it is surfaced: when the live id has
-- drifted from the pin, the winbar says so, because that means the agent no
-- longer holds the original context.
--=============================================================================

local sessionful = require("codecompanion.interactions.chat.sessionful")

local M = { _pinned = {} }

local WINBAR = "%{%v:lua.require('codecompanion.interactions.chat.ui.session_pin').winbar()%}"

---Pin `sid` for `bufnr` if nothing is pinned yet (first write wins).
---@param bufnr number|nil
---@param sid string|nil
function M.pin(bufnr, sid)
  if not bufnr or type(sid) ~= "string" or sid == "" then
    return
  end
  if M._pinned[bufnr] == nil then
    M._pinned[bufnr] = sid
    -- A late first-establish happens after the window (and its winbar
    -- expression) already rendered "pending"; nudge a redraw.
    pcall(vim.cmd.redrawstatus)
  end
end

---@param bufnr number|nil
---@return string|nil
function M.get(bufnr)
  return bufnr and M._pinned[bufnr] or nil
end

---@param bufnr number|nil
function M.reset(bufnr)
  if bufnr then
    M._pinned[bufnr] = nil
  end
end

---Winbar expression target, evaluated per-window per-redraw. Returns a
---statusline string (highlight items are allowed because of the `%{%...%}`
---wrapper). Empty for non-chat windows.
---@return string
function M.winbar()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "codecompanion" then
    return ""
  end

  local sid = M._pinned[bufnr]
  if not sid then
    return "%#Comment# session: (pending) %*"
  end

  local label = "%#Constant# session: " .. sid .. " %*"

  local ok, cc = pcall(require, "codecompanion")
  if ok then
    local live = sessionful.session_id(cc.buf_get_chat(bufnr))
    if type(live) == "string" and live ~= "" and live ~= sid then
      label = label .. "%#DiagnosticWarn# ≠ live: " .. live .. " %*"
    end
  end

  return label
end

function M.setup()
  local group = vim.api.nvim_create_augroup("codecompanion_chat_session_pin", { clear = true })

  -- Attach the winbar to any window showing a chat buffer. BufWinEnter +
  -- FileType together cover first open, toggle re-show, and tab moves.
  vim.api.nvim_create_autocmd({ "BufWinEnter", "FileType" }, {
    group = group,
    callback = function(args)
      local buf = args.buf
      if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        return
      end
      if vim.bo[buf].filetype ~= "codecompanion" then
        return
      end
      local win = vim.fn.bufwinid(buf)
      if win == -1 then
        return
      end
      vim.wo[win].winbar = WINBAR
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeCompanionChatClosed",
    callback = function(args)
      local bufnr = args.data and args.data.bufnr
      if bufnr then
        M.reset(bufnr)
      end
    end,
  })

  -- Omnigent chats pin on their durable session id, established (create) or
  -- resumed (load). Mirrors how the ACP paths pin on first establish.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "CodeCompanionOmnigentSessionReady", "CodeCompanionOmnigentChatRestored" },
    callback = function(args)
      local d = args.data or {}
      if d.bufnr and d.session_id then
        M.pin(d.bufnr, d.session_id)
      end
    end,
  })
end

return M
