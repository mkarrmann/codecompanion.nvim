--=============================================================================
-- Per-tab input box and message queue.
--
-- Replaces typing directly into the chat buffer with three stacked panes below
-- the chat: an input box, a status line, and one window per queued message. The
-- chat transcript can then be kept read-only, so it is only ever written
-- through this path.
--
-- Enforces a per-tab invariant: each tabpage owns at most one chat, and that
-- chat's input box, status line, queue, and timing all belong to the same tab.
-- Tab ownership is stamped on the chat buffer as `vim.b[bufnr].cc_tab_owner`
-- by whoever drives the lifecycle hooks below (`on_chat_opened` and friends);
-- this module reads that stamp to route events to the right per-tab state.
--
-- Status-line rendering (segments, wrapping, the 1s tick) lives in the sibling
-- `statusline` module and is invoked from here on draft/state changes.
--=============================================================================

local config = require("codecompanion.config")
local statusline = require("codecompanion.interactions.chat.queue.statusline")

local M = {}

--- @class CCQueueState
--- @field bufnr number?         input draft buffer
--- @field winnr number?         input window
--- @field status_bufnr number?  status-line buffer
--- @field status_winnr number?  status-line window
--- @field chat_bufnr number?    the chat buffer this queue feeds
--- @field queue CCQueueEntry[]  FIFO of pending messages, flushed one/turn
--- @field queued boolean        derived: #queue > 0 (drives statusline/highlight)
--- @field hold_from number?     derived: index of the first entry being edited;
---                              it and everything after it are held (queue paused)
--- @field fullscreen boolean
--- @field request_start_at number?
--- @field in_flight_id any      request id of the in-flight prompt, or nil
--- @field last_finished_status string? "success" | "cancelled" | "error" | ...
--- @field hist_idx number?      index into shared history while browsing, or nil
--- @field hist_stash string?    in-progress draft saved when history browse began

--- A single pending message. `text` is the committed value that will be sent;
--- the buffer holds the user's possibly-uncommitted edit of it.
--- @class CCQueueEntry
--- @field id number        monotonic, never reused; names the buffer
--- @field text string      committed text (what a flush sends)
--- @field bufnr number?    editable scratch buffer
--- @field winnr number?    window showing it, while the stack is up

--- @type table<number, CCQueueState>
local states = {}

-- Read at use time, not load time: `setup()` may run before the user's config
-- has been merged in.
local function opts()
  return config.display.queue
end

-- Resolve the owning tab for a chat buffer. The owner is stamped on the
-- buffer at chat-open time; if the stamp is missing or the tab no longer
-- exists, returns nil.
local function tab_for_chat(chat_bufnr)
  if not chat_bufnr or not vim.api.nvim_buf_is_valid(chat_bufnr) then
    return nil
  end
  local ok, t = pcall(function()
    return vim.b[chat_bufnr].cc_tab_owner
  end)
  if not (ok and t) then
    return nil
  end
  if not vim.api.nvim_tabpage_is_valid(t) then
    return nil
  end
  return t
end

local function tab_for_input(input_bufnr)
  input_bufnr = input_bufnr or vim.api.nvim_get_current_buf()
  local ok, input_tab = pcall(function()
    return vim.b[input_bufnr].cc_input_tab
  end)
  if ok and input_tab and vim.api.nvim_tabpage_is_valid(input_tab) then
    return input_tab
  end
  return vim.api.nvim_get_current_tabpage()
end

local function update_ui(s)
  statusline.apply_winhighlight(s)
  statusline.refresh(s)
end

local function get_draft_text(s)
  if not s.bufnr or not vim.api.nvim_buf_is_valid(s.bufnr) then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(s.bufnr, 0, -1, false)
  local text = vim.trim(table.concat(lines, "\n"))
  return text ~= "" and text or nil
end

local function clear_draft_buf(s)
  if s.bufnr and vim.api.nvim_buf_is_valid(s.bufnr) then
    s.suppress_unqueue = true
    vim.api.nvim_buf_set_lines(s.bufnr, 0, -1, false, {})
    s.suppress_unqueue = false
  end
  s.hist_idx = nil
  s.hist_stash = nil
  update_ui(s)
end

-- ─── Queued-message entries (one editable buffer + window each) ────────────
--
-- Each pending message is a real scratch buffer in its own split above the
-- input box, stacked in flush order (head at top, newest just above the box).
-- They are ordinary buffers, so the queue is navigated and edited with plain
-- Neovim motions rather than a bespoke pane.
--
-- The windows are *derived* from `s.queue`: closing one with <C-w>c does not
-- drop the message, it reappears on the next sync. Dropping is always the
-- explicit drop mapping, so a stray window close can't destroy typed text.
--
-- Hold semantics: an entry whose text differs from its committed value is
-- being edited, and is therefore not eligible to be sent. Since only the head
-- is ever flushed, "hold entry i and everything queued after it" reduces to the
-- single rule *flush the head only while the head is clean* -- no separate
-- hold-point state to keep in sync. Committing adopts the edit as the new
-- committed value and, if the chat is idle, resumes the flush immediately
-- (nothing else would wake it).

M.INPUT_FILETYPE = "codecompanion_input"
M.ENTRY_FILETYPE = "codecompanion_queue_entry"

-- Monotonic and never reused, so buffer names stay stable and unambiguous as
-- the queue drains (`:b cc-queue://7` means the same message all its life).
local next_entry_id = 0

-- Forward declarations: the entry and input keymaps close over handlers
-- defined further down, once submit/flush exist.
local commit_entry, drop_entry, steer_entry, steer_draft, focus_newest_entry

local function entry_buf_valid(e)
  return e and e.bufnr and vim.api.nvim_buf_is_valid(e.bufnr)
end

local function entry_win_valid(e)
  return e and e.winnr and vim.api.nvim_win_is_valid(e.winnr)
end

-- The live buffer contents (what the user sees), which differs from
-- `e.text` (the last committed value) precisely while the entry is dirty.
local function entry_buf_text(e)
  if not entry_buf_valid(e) then
    return e.text
  end
  local lines = vim.api.nvim_buf_get_lines(e.bufnr, 0, -1, false)
  return vim.trim(table.concat(lines, "\n"))
end

-- True while the user has uncommitted edits in this entry.
--
-- Compares against the committed text rather than reading Neovim's own
-- 'modified': a 'nofile' buffer never sets that flag, so it is always false
-- here. Comparing also means undoing back to the original text clears the
-- hold, which is what the user would expect.
local function entry_dirty(e)
  return entry_buf_valid(e) and entry_buf_text(e) ~= e.text
end

local function write_entry_buf(e, text)
  if not entry_buf_valid(e) then
    return
  end
  vim.api.nvim_buf_set_lines(e.bufnr, 0, -1, false, vim.split(text or "", "\n"))
end

local function find_entry(s, id)
  for i, e in ipairs(s.queue) do
    if e.id == id then
      return i, e
    end
  end
end

-- Index of the first entry being edited, or nil. Everything at or after it is
-- held; everything before it still flows.
local function hold_index(s)
  for i, e in ipairs(s.queue) do
    if entry_dirty(e) then
      return i
    end
  end
end

local function create_entry_buf(t, entry)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = M.ENTRY_FILETYPE
  pcall(vim.api.nvim_buf_set_name, buf, "cc-queue://" .. entry.id)
  -- Lets `tab_for_input` resolve this buffer's chat, so completion sources
  -- keep working while editing a queued message.
  vim.b[buf].cc_input_tab = t
  vim.b[buf].cc_queue_entry_id = entry.id

  local id = entry.id
  local keys = opts().keymaps
  vim.keymap.set({ "n", "i" }, keys.commit, function()
    commit_entry(t, id)
  end, { buffer = buf, desc = "Commit queued message (re-queue it)" })
  vim.keymap.set({ "n", "i" }, keys.drop, function()
    drop_entry(t, id)
  end, { buffer = buf, desc = "Drop this queued message" })
  vim.keymap.set({ "n", "i" }, keys.steer, function()
    steer_entry(t, id)
  end, { buffer = buf, desc = "Send this message next (steer the running turn where supported)" })

  return buf
end

local function setup_entry_win(w)
  vim.wo[w].number = false
  vim.wo[w].relativenumber = false
  vim.wo[w].signcolumn = "no"
  vim.wo[w].winfixbuf = true
  vim.wo[w].winfixheight = true
  vim.wo[w].wrap = true
  vim.wo[w].linebreak = true
  vim.wo[w].cursorline = false
end

-- Per-window winbar carries the entry's position and state, and the window tint
-- carries the one thing worth reading at a glance: yellow means this message
-- goes out as things stand, grey means it does not (it is being edited, or held
-- behind one that is).
--
-- It has to be the winbar rather than the statusline: with laststatus=3 the
-- window-local statuslines are never drawn.
local QUEUED_HL = "Normal:CCQueuedNormal,EndOfBuffer:CCQueuedNormal,WinSeparator:CCQueuedBorder"
local HELD_HL = "Normal:CCHeldNormal,EndOfBuffer:CCHeldNormal,WinSeparator:CCHeldBorder"

-- What the send-next key is offering here, which depends on the harness.
--
-- "steer" only where a mid-turn post is actually folded into the running turn
-- (see Session:can_steer). Everywhere else it moves the message to the head of
-- the queue, which is still "this one goes next" -- just at the next turn
-- boundary. Promising interruption a harness cannot deliver is how you end up
-- mistrusting the whole affordance.
local function steer_verb(s)
  local chat = s.chat_bufnr and require("codecompanion").buf_get_chat(s.chat_bufnr)
  local session = chat and chat.omnigent_session
  if session and session.can_steer and session:can_steer() then
    return "steer"
  end
  return "send next"
end

local function paint_entry_labels(s)
  local hold = hold_index(s)
  local n = #s.queue
  local keys = opts().keymaps
  for i, e in ipairs(s.queue) do
    if entry_win_valid(e) then
      local label, hl
      if e.sending then
        -- In flight but not gone: the send may still be waiting for a moment
        -- when the runner will fold it into the turn, and it goes back to
        -- "queued" if the POST fails.
        label = string.format("%%#DiagnosticInfo# ↑ %d/%d sending…%%*", i, n)
        hl = HELD_HL
      elseif entry_dirty(e) then
        label = string.format(
          "%%#DiagnosticWarn# ✎ %d/%d editing %%#Comment#— %s commit · %s drop · %s %s%%*",
          i,
          n,
          keys.commit,
          keys.drop,
          keys.steer,
          steer_verb(s)
        )
        hl = HELD_HL
      elseif hold and i > hold then
        label = string.format("%%#Comment# ⏸ %d/%d held (editing #%d)%%*", i, n, hold)
        hl = HELD_HL
      else
        label = string.format("%%#Comment# » %d/%d queued%%*", i, n)
        hl = QUEUED_HL
      end
      vim.wo[e.winnr].winbar = label
      vim.wo[e.winnr].winhighlight = hl
    end
  end
end

-- Share the vertical budget across the visible entries. Each window costs its
-- text height plus one row of winbar, so the per-entry share is discounted by
-- one before clamping to the message's own length.
local function apply_entry_layout(s)
  local n = #s.queue
  if n == 0 then
    return
  end
  local o = opts()
  local budget = math.max(1, math.floor(vim.o.lines * o.entry_stack_ratio))
  local share = math.max(1, math.floor(budget / n) - 1)
  for _, e in ipairs(s.queue) do
    if entry_win_valid(e) then
      local want = math.min(vim.api.nvim_buf_line_count(e.bufnr), o.entry_max_rows, share)
      pcall(vim.api.nvim_win_set_height, e.winnr, math.max(1, want))
    end
  end
  -- Splitting shrank the input box; restore its height.
  if s.winnr and vim.api.nvim_win_is_valid(s.winnr) then
    pcall(vim.api.nvim_win_set_height, s.winnr, s.fullscreen and vim.o.lines or o.input_height)
  end
end

-- Give every entry a window, creating only the missing ones so an entry the
-- user is currently editing is never torn down and rebuilt under the cursor.
-- A new window is split above the next entry that already has one (falling
-- back to the input box), which puts it at the right position in the stack
-- regardless of which entry was missing.
local function sync_entries(s)
  if not (s.winnr and vim.api.nvim_win_is_valid(s.winnr)) then
    for _, e in ipairs(s.queue) do
      e.winnr = nil
    end
    return
  end

  local cur = vim.api.nvim_get_current_win()
  for i, e in ipairs(s.queue) do
    if not entry_win_valid(e) then
      local anchor = s.winnr
      for j = i + 1, #s.queue do
        if entry_win_valid(s.queue[j]) then
          anchor = s.queue[j].winnr
          break
        end
      end
      -- HACK: guard the WinNew redirect autocmd against grabbing this split
      -- (it fires while `prev` still points at one of our own windows).
      s.creating_entry_win = true
      vim.api.nvim_set_current_win(anchor)
      vim.cmd("aboveleft split")
      s.creating_entry_win = false
      local w = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(w, e.bufnr)
      setup_entry_win(w)
      e.winnr = w
    end
  end
  if vim.api.nvim_win_is_valid(cur) then
    vim.api.nvim_set_current_win(cur)
  end

  apply_entry_layout(s)
  paint_entry_labels(s)
end

-- Close every entry window but keep the buffers, so a hidden chat can be
-- reopened with its queue intact.
local function close_entry_windows(s)
  for _, e in ipairs(s.queue or {}) do
    if entry_win_valid(e) then
      pcall(vim.api.nvim_win_close, e.winnr, true)
    end
    e.winnr = nil
  end
end

local function destroy_entry(e)
  if entry_win_valid(e) then
    pcall(vim.api.nvim_win_close, e.winnr, true)
  end
  if entry_buf_valid(e) then
    pcall(vim.api.nvim_buf_delete, e.bufnr, { force = true })
  end
  e.winnr = nil
  e.bufnr = nil
end

local function destroy_entries(s)
  for _, e in ipairs(s.queue or {}) do
    destroy_entry(e)
  end
end

-- Recompute the derived `queued` flag from the queue and repaint every
-- surface that reflects queue contents: the input/status highlight, the
-- status line, and the per-entry windows.
local function sync_queue_ui(s)
  s.queued = s.queue ~= nil and #s.queue > 0
  s.hold_from = hold_index(s)
  update_ui(s)
  sync_entries(s)
end

local function push_entry(s, t, text)
  next_entry_id = next_entry_id + 1
  local entry = { id = next_entry_id, text = text }
  entry.bufnr = create_entry_buf(t, entry)
  write_entry_buf(entry, text)
  -- Repaint labels + status the moment the entry goes dirty or clean again;
  -- this is the only signal that pauses the queue, so it must be live.
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = entry.bufnr,
    callback = function()
      local st = states[t]
      if not st then
        return
      end
      st.hold_from = hold_index(st)
      paint_entry_labels(st)
      statusline.refresh(st)
    end,
  })
  s.queue[#s.queue + 1] = entry
  return entry
end

local function remove_entry(s, i)
  local e = table.remove(s.queue, i)
  if e then
    destroy_entry(e)
  end
  return e
end

-- Session-scoped prompt history, shared across every tab's input box (like
-- shell history). Oldest first. In-memory only -- not persisted across restarts.
local history = {}

local function push_history(text)
  if not text or text == "" then
    return
  end
  if history[#history] == text then
    return
  end
  history[#history + 1] = text
  local limit = opts().history_limit
  while #history > limit do
    table.remove(history, 1)
  end
end

-- Overwrite the input draft with `text` without tripping the TextChanged
-- unqueue/hist-reset handler, then park the cursor at the end.
local function set_draft_text(s, text)
  if not s.bufnr or not vim.api.nvim_buf_is_valid(s.bufnr) then
    return
  end
  local lines = vim.split(text or "", "\n")
  s.suppress_unqueue = true
  vim.api.nvim_buf_set_lines(s.bufnr, 0, -1, false, lines)
  s.suppress_unqueue = false
  if s.winnr and vim.api.nvim_win_is_valid(s.winnr) then
    local last = #lines
    vim.api.nvim_win_set_cursor(s.winnr, { last, #lines[last] })
  end
end

-- Step to an older prompt. On first step we stash the in-progress draft so
-- stepping back down past the newest entry restores it. `hist_idx` points at
-- the entry currently shown; `#history + 1` is the sentinel "working draft".
local function history_prev(t)
  local s = states[t]
  if not s or #history == 0 then
    return
  end
  if not s.hist_idx then
    s.hist_stash = get_draft_text(s) or ""
    s.hist_idx = #history + 1
  end
  if s.hist_idx > 1 then
    s.hist_idx = s.hist_idx - 1
  end
  set_draft_text(s, history[s.hist_idx])
end

-- Step to a newer prompt; stepping past the newest restores the stashed draft.
local function history_next(t)
  local s = states[t]
  if not s or not s.hist_idx then
    return
  end
  s.hist_idx = s.hist_idx + 1
  if s.hist_idx > #history then
    set_draft_text(s, s.hist_stash or "")
    s.hist_idx = nil
    s.hist_stash = nil
  else
    set_draft_text(s, history[s.hist_idx])
  end
end

local function slash_commands_for_chat(chat)
  if not chat then
    return {}
  end
  return require("codecompanion.providers.completion").slash_commands("chat", {
    bufnr = chat.bufnr,
    chat = chat,
    adapter = chat.adapter,
  })
end

local function find_slash_command(chat, text)
  return vim.iter(slash_commands_for_chat(chat)):find(function(item)
    return item.label == text
  end)
end

local function execute_slash_command(s, chat, item, text)
  if not (s and chat and item) then
    return false
  end
  item = vim.deepcopy(item)
  item.context = chat.buffer_context or item.context
  push_history(text or item.label)
  clear_draft_buf(s)
  local restore_lock = vim.api.nvim_buf_is_valid(chat.bufnr) and not vim.bo[chat.bufnr].modifiable
  local ok, err = xpcall(function()
    require("codecompanion.interactions.chat.slash_commands").run(item, chat)
  end, debug.traceback)
  if restore_lock and vim.api.nvim_buf_is_valid(chat.bufnr) then
    vim.bo[chat.bufnr].modified = false
    vim.bo[chat.bufnr].modifiable = false
  end
  if not ok then
    error(err)
  end
  return true
end

-- Append `text` to the chat buffer as a user message and call `chat:submit()`.
--
-- parser.messages walks captures from `chat.header_line - 1` (0-indexed),
-- so `header_line` must be 1-indexed and point AT the `## Me` heading or
-- tree-sitter never sees the role node and silently captures nothing.
--
-- Steady-state path: after every turn `ready_for_input` writes a fresh trailing
-- `## Me`. We reuse that heading and put our text under it -- this matches the
-- ordinary submit path, keeps any Context block (turn 1) attached to the user
-- message, and avoids a visible duplicate `## Me`.
--
-- Cold-start fallback: if no `## Me` exists at all (chat was just opened with
-- no Context block, or some odd state), append a fresh section.
--
-- Returns true on success, false if the chat went away mid-flight.
local function submit_to_chat(chat_bufnr, text)
  local chat = require("codecompanion").buf_get_chat(chat_bufnr)
  if not chat then
    return false
  end

  -- Callers may keep the chat buffer non-modifiable at rest so it can't be
  -- hand-edited. Unlock it for this programmatic write; chat:submit() re-locks
  -- when the request starts and Chat:reset re-locks when the turn ends.
  vim.bo[chat_bufnr].modifiable = true

  local lines = vim.api.nvim_buf_get_lines(chat_bufnr, 0, -1, false)

  local last_me_idx
  for i = #lines, 1, -1 do
    if lines[i] == "## Me" then
      last_me_idx = i
      break
    end
  end

  local text_lines = vim.split(text, "\n")

  if last_me_idx then
    -- Reuse the heading. Replace anything (blank or otherwise) that follows it
    -- with: a single blank separator, the existing content (if any), and then
    -- our text. In the common case where ready_for_input already wrote an empty
    -- trailing `## Me`, the "existing content" list is just blank lines, which
    -- collapse cleanly.
    local existing = {}
    for i = last_me_idx + 1, #lines do
      existing[#existing + 1] = lines[i]
    end

    while #existing > 0 and existing[#existing] == "" do
      existing[#existing] = nil
    end

    local new_tail = { "" }
    for _, l in ipairs(existing) do
      new_tail[#new_tail + 1] = l
    end
    if #existing > 0 then
      new_tail[#new_tail + 1] = ""
    end
    for _, l in ipairs(text_lines) do
      new_tail[#new_tail + 1] = l
    end

    vim.api.nvim_buf_set_lines(chat_bufnr, last_me_idx, -1, false, new_tail)
    chat.header_line = last_me_idx
  else
    local appended = {}
    if #lines > 0 and lines[#lines] ~= "" then
      appended[#appended + 1] = ""
    end
    appended[#appended + 1] = "## Me"
    appended[#appended + 1] = ""
    local header_line = #lines + #appended - 1
    for _, l in ipairs(text_lines) do
      appended[#appended + 1] = l
    end
    vim.api.nvim_buf_set_lines(chat_bufnr, #lines, #lines, false, appended)
    chat.header_line = header_line
  end

  chat:submit()
  return true
end

-- Submit `text` to the chat now, recording history and clearing the box on
-- success. Returns true on success. Caller guarantees the chat exists.
local function submit_now(s, text)
  if submit_to_chat(s.chat_bufnr, text) then
    push_history(text)
    clear_draft_buf(s)
    return true
  end
  vim.notify("CodeCompanion submit failed; draft kept.", vim.log.levels.WARN)
  return false
end

-- Send the head of the queue, if it is eligible. A dirty head means the user
-- is editing it, which pauses the queue -- and because only the head is ever
-- flushed, that single check is what keeps everything queued behind an edit
-- from jumping ahead of it.
local function flush_head(s)
  local e = s.queue[1]
  -- `sending` as well as dirty: a head already on its way out must not be
  -- submitted a second time by the flush.
  if not e or e.sending or entry_dirty(e) then
    return false
  end
  if not submit_to_chat(s.chat_bufnr, e.text) then
    return false
  end
  remove_entry(s, 1)
  sync_queue_ui(s)
  return true
end

-- Is the chat occupied, so a new prompt must queue rather than go out now?
--
-- `in_flight_id` only tracks FOREGROUND requests: it is set from
-- CodeCompanionRequestStarted, which is fired for a user submit and nothing
-- else. A background turn -- a wakeup, a turn driven from another client, or a
-- `/compact` posted on our behalf -- leaves it nil, so the box would look idle
-- and a send would shoot a prompt into a running turn.
--
-- The durable session's own status covers all of those uniformly, so prefer it
-- over instrumenting each event: it is maintained live from `session.status`
-- and settles when a turn ends, so it cannot get stuck busy. Non-omnigent
-- adapters have no session and fall back to the foreground flag alone.
local function chat_busy(s, chat)
  if s.in_flight_id then
    return true
  end
  local session = chat and chat.omnigent_session
  return (session and session.busy and session:busy()) or false
end

-- The send mapping from the input box.
--
--  * Idle + empty queue       → submit the draft immediately.
--  * Busy or queue non-empty  → append the draft to the FIFO and free the box
--                               for the next message.
--  * Empty box + queue paused → flush the head now (resume; see `on_chat_done`,
--                               which pauses on cancel/error).
local function send(t)
  local s = states[t]
  if not s then
    return
  end

  local chat = require("codecompanion").buf_get_chat(s.chat_bufnr)
  if not chat then
    -- Chat is gone but the input window is still open. Leave the draft so the
    -- user can copy it; queuing would never flush.
    vim.notify("CodeCompanion chat is closed; draft kept in input box.", vim.log.levels.WARN)
    return
  end

  local text = get_draft_text(s)
  if not text then
    -- Nothing to send. Resume a paused queue if one is waiting.
    if not chat_busy(s, chat) then
      flush_head(s)
    end
    return
  end

  local slash_command = find_slash_command(chat, text)
  if slash_command then
    execute_slash_command(s, chat, slash_command, text)
    return
  end

  if not chat_busy(s, chat) and #s.queue == 0 then
    submit_now(s, text)
    return
  end

  push_entry(s, t, text)
  push_history(text)
  clear_draft_buf(s)
  sync_queue_ui(s)
end

-- ─── Per-entry actions (bound in the entry buffers) ────────────────────────

local function focus_input(s)
  if s.winnr and vim.api.nvim_win_is_valid(s.winnr) then
    vim.api.nvim_set_current_win(s.winnr)
  end
end

-- Commit in an entry buffer: adopt the edited text as the message that will be
-- sent, which releases this entry and everything held behind it. An emptied
-- entry is a delete -- the same instinct as clearing the input box to discard a
-- draft.
function commit_entry(t, id)
  local s = states[t]
  if not s then
    return
  end
  local i, e = find_entry(s, id)
  if not e then
    return
  end

  local text = entry_buf_text(e)
  if text == "" then
    remove_entry(s, i)
    vim.notify("Queued message dropped (empty)", vim.log.levels.INFO)
    focus_input(s)
  else
    e.text = text
  end

  sync_queue_ui(s)
  -- Nothing else will wake a queue that paused while the chat sat idle, so
  -- releasing the last hold has to kick the flush itself.
  local chat = require("codecompanion").buf_get_chat(s.chat_bufnr)
  if chat and not chat_busy(s, chat) then
    flush_head(s)
  end
end

-- Drop in an entry buffer: discard the message. Deliberately explicit --
-- closing the window does not do this, so a stray <C-w>c can't destroy text.
function drop_entry(t, id)
  local s = states[t]
  if not s then
    return
  end
  local i = find_entry(s, id)
  if not i then
    return
  end
  remove_entry(s, i)
  focus_input(s)
  sync_queue_ui(s)
end

-- How <C-CR> should deliver `text` right now.
--
--   "submit"  nothing is running, so this is an ordinary send
--   "steer"   a turn is running AND this harness folds a mid-turn post into it
--   "queue"   a turn is running and it does not -- posting out of band would buy
--             a few hundred milliseconds and cost the whole foreground render
--             path (no RequestStarted, so no timer, and the reply arrives after
--             the handler has detached, landing on the background observer
--             below an orphaned `## Me`). Putting it at the head of the queue
--             gets the same message into the same next turn, rendered properly.
local function send_now_mode(s, chat)
  if not chat_busy(s, chat) then
    return "submit"
  end
  local session = chat.omnigent_session
  if session and session.can_steer and session:can_steer() then
    return "steer"
  end
  return "queue"
end

-- Post `text` into the turn that is already running.
--
-- `on_sent` fires when the POST settles, not when it is accepted -- the wait for
-- a steerable moment can outlive this call, and the caller must not throw the
-- text away before it is actually gone.
local function steer_post(s, chat, text, on_sent)
  local handler = require("codecompanion.interactions.chat.omnigent.handler")
  local ok, err = handler.steer(chat, text, on_sent)
  if not ok then
    vim.notify("Cannot steer: " .. tostring(err), vim.log.levels.WARN)
    return false
  end
  return true
end

-- Move an entry to the front so it is the next thing flushed.
--
-- Drops every entry window on the way out. `sync_entries` only creates the ones
-- that are missing -- deliberately, so an entry being edited is never rebuilt
-- under the cursor -- which means a surviving window keeps its old position and
-- the stack stops matching flush order. Rebuilding the whole stack is the only
-- thing that keeps "top of the stack goes next" true.
local function move_to_head(s, i)
  if i <= 1 then
    return false
  end
  table.insert(s.queue, 1, table.remove(s.queue, i))
  close_entry_windows(s)
  return true
end

-- Send this entry next rather than waiting its turn. Deliberately jumps the
-- FIFO -- it is the one action here that does, which is why it is a different
-- key from commit. Whether that means steering the running turn or moving to the
-- head of the queue depends on the harness; either way "next" is what it means.
--
-- On the steer path the entry is held (marked "sending") until the POST lands,
-- and restored if it fails: the wait for a steerable moment can outlive this
-- call, so dropping it on acceptance would lose the text in that window.
--
-- An uncommitted edit is adopted first. Asking to send a message you have just
-- retyped can only mean the retyped version.
function steer_entry(t, id)
  local s = states[t]
  if not s then
    return
  end
  local i, e = find_entry(s, id)
  if not e then
    return
  end

  local text = entry_buf_text(e)
  if text == "" then
    vim.notify("Nothing to send", vim.log.levels.INFO)
    return
  end
  e.text = text

  local chat = require("codecompanion").buf_get_chat(s.chat_bufnr)
  if not chat then
    vim.notify("CodeCompanion chat is closed", vim.log.levels.WARN)
    return
  end

  local mode = send_now_mode(s, chat)
  if mode ~= "steer" then
    if not move_to_head(s, i) then
      vim.notify("Already next in the queue", vim.log.levels.INFO)
    end
    sync_queue_ui(s)
    if mode == "submit" then
      flush_head(s)
    end
    return
  end

  e.sending = true
  sync_queue_ui(s)
  local accepted = steer_post(s, chat, text, function(sent)
    local st = states[t]
    if not st then
      return
    end
    local idx, entry = find_entry(st, id)
    if not entry then
      return
    end
    entry.sending = false
    if sent then
      remove_entry(st, idx)
      focus_input(st)
    end
    sync_queue_ui(st)
  end)
  if not accepted then
    e.sending = false
    sync_queue_ui(s)
  end
end

-- Send the draft next instead of behind everything already queued. Same
-- three-way as an entry; the draft is kept until the send actually lands.
function steer_draft(t)
  local s = states[t]
  if not s then
    return
  end
  local text = get_draft_text(s)
  if not text then
    vim.notify("Nothing to send", vim.log.levels.INFO)
    return
  end
  local chat = require("codecompanion").buf_get_chat(s.chat_bufnr)
  if not chat then
    vim.notify("CodeCompanion chat is closed", vim.log.levels.WARN)
    return
  end

  local mode = send_now_mode(s, chat)
  if mode == "submit" then
    submit_now(s, text)
    return
  end
  if mode == "queue" then
    local e = push_entry(s, t, text)
    move_to_head(s, #s.queue)
    push_history(text)
    clear_draft_buf(s)
    sync_queue_ui(s)
    return e
  end

  steer_post(s, chat, text, function(sent)
    local st = states[t]
    if not (st and sent) then
      return
    end
    push_history(text)
    clear_draft_buf(st)
  end)
end

-- Hop into the most recently queued message. Just a shortcut -- the entries are
-- ordinary buffers, so any window/buffer motion reaches them too.
function focus_newest_entry(t)
  local s = states[t]
  if not s then
    return
  end
  local e = s.queue[#s.queue]
  if not e then
    vim.notify("No queued messages", vim.log.levels.INFO)
    return
  end
  if not entry_win_valid(e) then
    sync_entries(s)
  end
  if entry_win_valid(e) then
    vim.api.nvim_set_current_win(e.winnr)
  end
end

local function toggle_fullscreen(t)
  local s = states[t]
  if not s or not s.winnr or not vim.api.nvim_win_is_valid(s.winnr) then
    return
  end
  vim.api.nvim_win_set_height(s.winnr, s.fullscreen and opts().input_height or vim.o.lines)
  s.fullscreen = not s.fullscreen
end

local function create_input_buf(t)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = M.INPUT_FILETYPE
  vim.bo[buf].bufhidden = "hide"
  vim.b[buf].cc_input_tab = t

  local keys = opts().keymaps
  vim.keymap.set({ "n", "i" }, keys.send, function()
    send(t)
  end, { buffer = buf, desc = "Send/queue prompt" })
  vim.keymap.set({ "n", "i" }, keys.fullscreen, function()
    toggle_fullscreen(t)
  end, { buffer = buf, desc = "Toggle fullscreen" })
  vim.keymap.set({ "n", "i" }, keys.focus_newest, function()
    focus_newest_entry(t)
  end, { buffer = buf, desc = "Jump to the newest queued message" })
  vim.keymap.set({ "n", "i" }, keys.steer, function()
    steer_draft(t)
  end, { buffer = buf, desc = "Send the draft next (steer the running turn where supported)" })

  -- Edge-triggered history navigation: the history keys browse prompt history
  -- only at the first/last line, and otherwise fall through to ordinary cursor
  -- movement within a multi-line draft.
  vim.keymap.set({ "n", "i" }, keys.history_prev, function()
    if vim.api.nvim_win_get_cursor(0)[1] > 1 then
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys.history_prev, true, false, true), "n", false)
    else
      history_prev(t)
    end
  end, { buffer = buf, desc = "Previous prompt / move up" })
  vim.keymap.set({ "n", "i" }, keys.history_next, function()
    if vim.api.nvim_win_get_cursor(0)[1] < vim.api.nvim_buf_line_count(buf) then
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys.history_next, true, false, true), "n", false)
    else
      history_next(t)
    end
  end, { buffer = buf, desc = "Next prompt / move down" })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = function()
      local s = states[t]
      if not s or s.suppress_unqueue then
        return
      end
      -- A manual edit ends any history browse and forks a fresh draft. The
      -- queue is independent of the box, so editing the draft unqueues nothing.
      s.hist_idx = nil
      s.hist_stash = nil
    end,
  })

  return buf
end

-- Re-entrancy guard for teardown. `M.teardown` closes windows and the chat
-- buffer, each of which fires events (WinClosed, ChatClosed) that route back
-- here; the guard makes those nested calls no-ops so the single in-progress
-- teardown owns the whole sequence.
local tearing_down = {}

-- Bring down a tab's entire chat UI together and synchronously: the chat
-- window+buffer, the input window+buffer, the status window+buffer, the
-- status-line timer, the per-tab state, and the tab var. This is the single
-- teardown path -- every close entry point (chat closed, input/status window
-- closed, tab closed) funnels here so the panes always live and die as a unit.
--
-- Idempotent: safe to call repeatedly and re-entrantly. Closing the chat buffer
-- here fires `CodeCompanionChatClosed` -> `on_chat_closed` -> `teardown` again;
-- the guard (and the `states[t]` nil check) absorb the re-entry. Also handles
-- the "chat buffer already deleted" case, since `Chat:close` fires ChatClosed
-- and only then deletes the buffer -- so by the time a scheduled handler runs
-- the buffer (and its tab stamp) may be gone, which is why callers pass the
-- resolved tab in explicitly.
function M.teardown(t)
  if not t then
    return
  end
  local s = states[t]
  if not s then
    return
  end
  if tearing_down[t] then
    return
  end
  tearing_down[t] = true

  statusline.stop(s)
  destroy_entries(s)

  -- Close the chat window(s) in the owning tab. Window close doesn't delete the
  -- chat buffer; that happens below via chat:close().
  if s.chat_bufnr and vim.api.nvim_tabpage_is_valid(t) then
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(t)) do
      if vim.api.nvim_win_get_buf(win) == s.chat_bufnr then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end
  if s.status_winnr and vim.api.nvim_win_is_valid(s.status_winnr) then
    pcall(vim.api.nvim_win_close, s.status_winnr, true)
  end
  if s.winnr and vim.api.nvim_win_is_valid(s.winnr) then
    pcall(vim.api.nvim_win_close, s.winnr, true)
  end

  -- Close the chat itself. Prefer chat:close() when the chat still exists so
  -- its connection is disconnected; fall back to a raw buffer delete. When we
  -- got here *from* a ChatClosed event the chat is already gone
  -- (buf_get_chat -> nil, buffer invalid) and both branches are skipped.
  if s.chat_bufnr and vim.api.nvim_buf_is_valid(s.chat_bufnr) then
    local chat = require("codecompanion").buf_get_chat(s.chat_bufnr)
    if chat then
      pcall(function()
        chat:close()
      end)
    else
      pcall(vim.api.nvim_buf_delete, s.chat_bufnr, { force = true })
    end
  end
  if s.bufnr and vim.api.nvim_buf_is_valid(s.bufnr) then
    pcall(vim.api.nvim_buf_delete, s.bufnr, { force = true })
  end
  if s.status_bufnr and vim.api.nvim_buf_is_valid(s.status_bufnr) then
    pcall(vim.api.nvim_buf_delete, s.status_bufnr, { force = true })
  end

  if vim.api.nvim_tabpage_is_valid(t) then
    pcall(vim.api.nvim_tabpage_del_var, t, "codecompanion_chat_bufnr")
  end

  states[t] = nil
  tearing_down[t] = nil
end

function M.on_chat_opened(chat_bufnr)
  local t = tab_for_chat(chat_bufnr)
  if not t then
    return
  end

  local s = states[t]
  if s and s.winnr and vim.api.nvim_win_is_valid(s.winnr) then
    s.chat_bufnr = chat_bufnr
    return
  end

  s = s or {}
  states[t] = s

  if not s.bufnr or not vim.api.nvim_buf_is_valid(s.bufnr) then
    s.bufnr = create_input_buf(t)
  end
  if not s.status_bufnr or not vim.api.nvim_buf_is_valid(s.status_bufnr) then
    s.status_bufnr = statusline.create_buf()
  end

  s.chat_bufnr = chat_bufnr
  s.queue = s.queue or {}
  s.queued = #s.queue > 0
  s.suppress_unqueue = false
  s.fullscreen = false

  local chat_winnr = vim.fn.bufwinid(chat_bufnr)
  if chat_winnr == -1 then
    return
  end

  local prev_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(chat_winnr)

  vim.cmd("belowright split")
  local input_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(input_win, s.bufnr)

  vim.cmd("belowright split")
  local status_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(status_win, s.status_bufnr)

  vim.wo[status_win].winfixheight = true
  vim.api.nvim_win_set_height(status_win, 1)
  vim.api.nvim_win_set_height(input_win, opts().input_height)

  for _, w in ipairs({ status_win, input_win }) do
    vim.wo[w].number = false
    vim.wo[w].relativenumber = false
    vim.wo[w].signcolumn = "no"
    vim.wo[w].winfixheight = true
    vim.wo[w].winfixbuf = true
    vim.wo[w].statusline = " "
    vim.wo[w].wrap = true
    vim.wo[w].linebreak = true
  end
  vim.wo[status_win].cursorline = false

  s.winnr = input_win
  s.status_winnr = status_win
  update_ui(s)
  statusline.start(s)
  -- Restore the entry windows if this tab reopened with a pending queue.
  sync_entries(s)

  -- HACK: On first open, focus the input box. On subsequent opens (toggle
  -- cycles), restore focus to wherever the user was -- the chat toggle already
  -- handles focus for the chat pane.
  if prev_win == chat_winnr then
    vim.api.nvim_set_current_win(input_win)
    vim.cmd("startinsert")
  else
    vim.api.nvim_set_current_win(prev_win)
  end
end

function M.on_chat_hidden(chat_bufnr)
  local t = tab_for_chat(chat_bufnr)
  if not t then
    return
  end
  local s = states[t]
  if not s or s.chat_bufnr ~= chat_bufnr then
    return
  end
  s.fullscreen = false
  -- Windows only: the entry buffers (and any uncommitted edits in them) are
  -- kept so a re-opened chat comes back with its queue intact.
  close_entry_windows(s)
  -- Null the window handles *before* closing so the WinClosed handler sees no
  -- matching winnr/status_winnr and treats this as a toggle-off, not a full
  -- teardown. The input/status buffers are kept for re-open.
  local status_winnr, winnr = s.status_winnr, s.winnr
  s.status_winnr = nil
  s.winnr = nil
  if status_winnr and vim.api.nvim_win_is_valid(status_winnr) then
    pcall(vim.api.nvim_win_close, status_winnr, true)
  end
  if winnr and vim.api.nvim_win_is_valid(winnr) then
    pcall(vim.api.nvim_win_close, winnr, true)
  end
  statusline.stop(s)
end

-- Auto-flush the queue one message per turn. On success, pop the head and
-- submit it; the next turn's completion flushes the following one, and so on.
-- On cancel/error the queue is left intact (pause): nothing is lost, and the
-- user resumes with an empty send in the input box (see `send`) once things
-- look right.
function M.on_chat_done(chat_bufnr)
  local t = tab_for_chat(chat_bufnr)
  if not t then
    return
  end
  local s = states[t]
  if not s or not s.queue or #s.queue == 0 or s.chat_bufnr ~= chat_bufnr then
    return
  end

  if s.last_finished_status and s.last_finished_status ~= "success" then
    sync_queue_ui(s)
    return
  end

  -- No-op when the head is being edited; the queue stays paused until the edit
  -- is committed or dropped (see flush_head).
  flush_head(s)
  sync_queue_ui(s)
end

-- Chat closed (by us or by CodeCompanion). Routes to the unified teardown. The
-- tab is passed in explicitly by the ChatClosed handler because the chat buffer
-- is deleted synchronously inside `Chat:close` right after firing ChatClosed,
-- so by the time this runs the buffer -- and its `cc_tab_owner` stamp -- may
-- already be gone, making `tab_for_chat` return nil. Fall back to it only when
-- no tab was provided.
function M.on_chat_closed(chat_bufnr, tab)
  M.teardown(tab or tab_for_chat(chat_bufnr))
end

---The input bufnr for the current tab. Used by completion sources.
---@return number|nil
function M.bufnr()
  local s = states[vim.api.nvim_get_current_tabpage()]
  return s and s.bufnr or nil
end

---The chat bufnr a completion source should target. Resolves via the input
---buffer the user is typing in (which knows its owning tab), falling back to
---the current tab's chat.
---@return number|nil
function M.chat_bufnr()
  local s = states[tab_for_input()]
  return s and s.chat_bufnr or nil
end

function M.slash_commands()
  local s = states[tab_for_input()]
  local chat = s and s.chat_bufnr and require("codecompanion").buf_get_chat(s.chat_bufnr)
  return slash_commands_for_chat(chat)
end

function M.execute_slash(item)
  local s = states[tab_for_input()]
  local chat = s and s.chat_bufnr and require("codecompanion").buf_get_chat(s.chat_bufnr)
  return execute_slash_command(s, chat, item)
end

-- Lifecycle hooks driven by `User CodeCompanionRequestStarted/Finished`. The
-- id-based matching is the canonical "in flight" signal -- `chat.current_request`
-- is unreliable across cancellation (Chat:stop() clears it synchronously while
-- the finish handler runs later).
function M.on_request_started(bufnr, id)
  local t = tab_for_chat(bufnr)
  if not t then
    return
  end
  local s = states[t]
  if not s or s.chat_bufnr ~= bufnr then
    return
  end
  s.in_flight_id = id or true
  s.last_finished_status = nil
  s.request_start_at = os.time()
  statusline.refresh(s)
end

function M.on_request_finished(bufnr, id, status)
  local t = tab_for_chat(bufnr)
  if not t then
    return
  end
  local s = states[t]
  if not s or s.chat_bufnr ~= bufnr then
    return
  end
  -- Only clear if this is the request we were tracking. Out-of-order Finished
  -- events (e.g. from a previous cancelled request arriving after a newer one
  -- started) must not blow away in-flight state.
  if id == nil or s.in_flight_id == nil or s.in_flight_id == id or s.in_flight_id == true then
    s.in_flight_id = nil
    s.request_start_at = nil
    s.last_finished_status = status
  end
  statusline.refresh(s)
end

function M.focus()
  local s = states[vim.api.nvim_get_current_tabpage()]
  if s and s.winnr and vim.api.nvim_win_is_valid(s.winnr) then
    vim.api.nvim_set_current_win(s.winnr)
    vim.cmd("startinsert")
  else
    vim.notify("No CodeCompanion input box open in this tab", vim.log.levels.WARN)
  end
end

---Install the window-lifecycle autocmds and the queue highlight groups.
---Idempotent.
function M.setup()
  statusline.setup()

  -- When a sibling input/status window closes, tear the whole UI down -- the
  -- panes are a unit (see `M.teardown`). Matching is per-tab via the stamped
  -- winnr/status_winnr, so a `:tab split` can't close the wrong tab's chat.
  --
  -- The hide path (`on_chat_hidden`) nulls these fields *before* closing its
  -- windows precisely so this handler doesn't mistake a toggle-off for a
  -- teardown.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = vim.api.nvim_create_augroup("codecompanion_queue_close", { clear = true }),
    callback = function(args)
      local closed = tonumber(args.match)
      if not closed then
        return
      end
      for t, s in pairs(states) do
        -- Entry windows come and go with the queue; closing one is never a
        -- teardown, and it doesn't drop the message either -- the window is
        -- derived from the queue and returns on the next sync.
        for _, e in ipairs(s.queue or {}) do
          if closed == e.winnr then
            e.winnr = nil
            return
          end
        end
        if closed == s.winnr or closed == s.status_winnr then
          return M.teardown(t)
        end
      end
    end,
  })

  -- When a new window is opened from the input or status pane, redirect it into
  -- a split alongside the chat -- but only when the chat lives in the same tab
  -- as the new window.
  vim.api.nvim_create_autocmd("WinNew", {
    group = vim.api.nvim_create_augroup("codecompanion_queue_redirect", { clear = true }),
    callback = function()
      local s = states[vim.api.nvim_get_current_tabpage()]
      if not s or not s.winnr or not vim.api.nvim_win_is_valid(s.winnr) then
        return
      end
      -- Queued-entry windows are deliberately split off the input window; don't
      -- redirect them into a chat split.
      if s.creating_entry_win then
        return
      end
      local prev = vim.fn.win_getid(vim.fn.winnr("#"))
      if prev ~= s.winnr and prev ~= s.status_winnr then
        return
      end

      local new_win = vim.api.nvim_get_current_win()
      -- Never redirect a floating window (opened from the input box, so `prev`
      -- matches s.winnr) into a split.
      if vim.api.nvim_win_get_config(new_win).relative ~= "" then
        return
      end
      vim.schedule(function()
        if not vim.api.nvim_win_is_valid(new_win) then
          return
        end
        local chat_win = s.chat_bufnr and vim.fn.bufwinid(s.chat_bufnr)
        if not chat_win or chat_win == -1 then
          return
        end
        if vim.api.nvim_win_get_tabpage(chat_win) ~= vim.api.nvim_win_get_tabpage(new_win) then
          return
        end

        local buf = vim.api.nvim_win_get_buf(new_win)
        -- HACK: pin bufhidden across the close so a buf with bufhidden=wipe
        -- isn't destroyed when its only window closes.
        local prev_bufhidden = vim.bo[buf].bufhidden
        vim.bo[buf].bufhidden = "hide"
        vim.api.nvim_win_close(new_win, false)
        vim.api.nvim_set_current_win(chat_win)
        vim.cmd("vertical rightbelow split")
        vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), buf)
        if vim.api.nvim_buf_is_valid(buf) then
          vim.bo[buf].bufhidden = prev_bufhidden
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd("TabClosed", {
    group = vim.api.nvim_create_augroup("codecompanion_queue_tabclosed", { clear = true }),
    callback = function()
      local valid = {}
      for _, t in ipairs(vim.api.nvim_list_tabpages()) do
        valid[t] = true
      end
      for t in pairs(states) do
        if not valid[t] then
          M.teardown(t)
        end
      end
    end,
  })
end

return M
