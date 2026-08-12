--=============================================================================
-- Per-session token / cost usage cache.
--
-- Durable adapters report usage as it accrues, but they report it as *events*,
-- not as state you can query: by the time a status line or lualine component
-- wants "how full is this context window", the notification that carried the
-- answer is long gone. This module is the small piece of state that closes that
-- gap -- it listens once, keys the latest {used, size, cost} by durable session
-- id, and hands it back synchronously.
--
-- Two producers, one shape:
--
--   * ACP -- `CodeCompanionACPSessionUpdate` with `sessionUpdate == "usage_update"`,
--     whose wire shape ({ used, size, cost? }) comes from @agentclientprotocol/sdk.
--   * Omnigent -- `CodeCompanionOmnigentUsage`, carrying
--     { context_tokens, context_window, total_cost_usd }.
--
-- `size` is sticky. The omnigent SSE usage event sends `context_window: null`
-- even though the session snapshot knows it, so a later null must not clear a
-- size that has already been learned.
--=============================================================================

local sessionful = require("codecompanion.interactions.chat.sessionful")

local M = { _by_session = {} }

---Latest usage for a durable session, or nil if none has been reported.
---@param session_id string|nil
---@return table|nil
function M.get(session_id)
  if not session_id then
    return nil
  end
  return M._by_session[session_id]
end

---Percentage of the context window consumed, or nil if the size is unknown.
---@param session_id string|nil
---@return number|nil
function M.context_pct(session_id)
  local s = M.get(session_id)
  if not s or not s.size or s.size == 0 then
    return nil
  end
  return math.floor(100 * s.used / s.size)
end

---Register the usage listeners. Idempotent, and safe to call before any chat
---exists -- which is the point: usage notifications for the very first prompt
---fire before anything would lazily pull this module in, and would be dropped.
function M.setup()
  local group = vim.api.nvim_create_augroup("codecompanion_chat_usage", { clear = true })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeCompanionACPSessionUpdate",
    callback = function(args)
      local data = args.data or {}
      local update = data.update
      local sid = data.session_id
      if not sid or not update or update.sessionUpdate ~= "usage_update" then
        return
      end
      M._by_session[sid] = {
        used = update.used,
        size = update.size,
        cost = update.cost,
      }
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeCompanionOmnigentUsage",
    callback = function(args)
      local d = args.data or {}
      local sid = d.session_id
      local usage = d.usage
      if not sid or type(usage) ~= "table" then
        return
      end
      local cur = M._by_session[sid] or {}
      if usage.context_tokens then
        cur.used = usage.context_tokens
      end
      if usage.context_window then
        cur.size = usage.context_window
      end
      if usage.total_cost_usd then
        cur.cost = { amount = usage.total_cost_usd, currency = "USD" }
      end
      M._by_session[sid] = cur
    end,
  })

  -- Evict on close. The event fires before the connection is torn down, so the
  -- chat can still resolve its session id.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeCompanionChatClosed",
    callback = function(args)
      local bufnr = args.data and args.data.bufnr
      if not bufnr then
        return
      end
      local ok, chat = pcall(function()
        return require("codecompanion").buf_get_chat(bufnr)
      end)
      if not ok or not chat then
        return
      end
      local sid = sessionful.session_id(chat)
      if sid then
        M._by_session[sid] = nil
      end
    end,
  })
end

return M
