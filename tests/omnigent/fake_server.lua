--=============================================================================
-- Scriptable fake omnigent stream + a recording mock chat, for M4 tests.
--
-- `scripted_job(connections)` returns an injectable stream-job factory: the Nth
-- job() call (i.e. the Nth stream open, so reconnects advance it) runs
-- connections[N] synchronously. Each connection is a list of actions:
--   { emit = "<raw sse text>" }              -- feed raw text to the parser
--   { event = "<type>", data = { ... } }     -- feed one SSE frame (type auto-set)
--   { exit = <code> }                        -- end the stream (triggers reconnect)
-- A connection with no `exit` stays open (returns a stop handle, never on_exit).
--
-- `mock_chat(adapter)` records add_buf_message / add_message so a test can assert
-- what was rendered without a real buffer.
--=============================================================================

local M = {}

---@param connections table[] list of connection action-lists
---@return function factory, table stats
function M.scripted_job(connections)
  local stats = { calls = 0, stopped = 0, handles = {} }
  local factory = function(o)
    stats.calls = stats.calls + 1
    local actions = connections[stats.calls] or {}
    for _, a in ipairs(actions) do
      if a.emit then
        o.on_stdout(a.emit)
      end
      if a.event then
        local payload = vim.tbl_extend("force", { type = a.event }, a.data or {})
        o.on_stdout("event: " .. a.event .. "\ndata: " .. vim.json.encode(payload) .. "\n\n")
      end
      if a.exit ~= nil then
        o.on_exit(a.exit)
      end
    end
    local handle = { stopped = false }
    handle.stop = function()
      handle.stopped = true
      stats.stopped = stats.stopped + 1
    end
    stats.handles[#stats.handles + 1] = handle
    return handle
  end
  return factory, stats
end

---A recording chat double sufficient for the observer/handler.
---@param adapter table
---@return table
function M.mock_chat(adapter)
  return {
    adapter = adapter,
    messages = {},
    bufnr = 0,
    id = 42,
    status = nil,
    omnigent_session = nil,
    omnigent_session_id = nil,
    MESSAGE_TYPES = {
      LLM_MESSAGE = "llm_msg",
      REASONING_MESSAGE = "reasoning_msg",
      TOOL_MESSAGE = "tool_msg",
      SYSTEM_MESSAGE = "sys_msg",
      USER_MESSAGE = "user_msg",
    },
    buf_calls = {},
    msg_calls = {},
    add_buf_message = function(self, msg, opts)
      table.insert(self.buf_calls, { role = msg.role, content = msg.content, type = opts and opts.type })
    end,
    add_message = function(self, msg, opts)
      msg._meta = (opts and opts._meta) or msg._meta
      table.insert(self.messages, msg)
      table.insert(self.msg_calls, { role = msg.role, content = msg.content, meta = msg._meta })
    end,
    update_metadata = function() end,
  }
end

---Concatenate the content of buffer messages of a given type (default llm_msg).
---@param chat table
---@param mtype? string
---@return string
function M.rendered_text(chat, mtype)
  mtype = mtype or "llm_msg"
  local parts = {}
  for _, b in ipairs(chat.buf_calls) do
    if b.type == mtype then
      parts[#parts + 1] = b.content
    end
  end
  return table.concat(parts)
end

return M
