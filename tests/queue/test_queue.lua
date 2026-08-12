local h = require("tests.helpers")
local new_set = MiniTest.new_set

local codecompanion = require("codecompanion")
local completion = require("codecompanion.providers.completion")
local config = require("codecompanion.config")
local queue = require("codecompanion.interactions.chat.queue")

-- Exercises the per-entry queue: the entry buffers/windows, the hold rule (an
-- entry being edited pauses the queue at that point, while entries ahead of it
-- keep flowing), commit, drop, and hide/re-open.

local saved = {}

local T = new_set({
  hooks = {
    pre_case = function()
      saved.buf_get_chat = codecompanion.buf_get_chat
      saved.slash_commands = completion.slash_commands
      saved.lines, saved.columns = vim.o.lines, vim.o.columns
      -- Whichever tests ran before this one may have left `config.config` as a
      -- bare table (see `config.defaults`), so back-fill the defaults rather
      -- than assume `display.queue` is still there.
      saved.config = config.config
      config.config = vim.tbl_deep_extend("force", vim.deepcopy(config.defaults), saved.config)
      -- The split stack does not fit in the default headless 80x24.
      vim.o.lines, vim.o.columns = 60, 200
      -- Resolving real slash commands against a fake chat is beside the point
      -- here, and would drag half the provider stack into a UI test.
      completion.slash_commands = function()
        return {}
      end
      queue.setup()
    end,
    post_case = function()
      -- Close the chat tabs before restoring the stubs: TabClosed drives the
      -- queue's teardown, which is what clears its per-tab state between cases.
      vim.cmd("silent! tabfirst")
      vim.cmd("silent! tabonly")
      vim.cmd("silent! only")
      codecompanion.buf_get_chat = saved.buf_get_chat
      completion.slash_commands = saved.slash_commands
      vim.o.lines, vim.o.columns = saved.lines, saved.columns
      config.config = saved.config
    end,
  },
})

-- Resolved per use, not at collection time: the back-fill above only runs once
-- the case starts.
local function keys()
  return config.display.queue.keymaps
end

---Entry windows top-to-bottom. nvim_tabpage_list_wins order is not guaranteed
---to match the visual stack, so sort by screen row.
local function entry_stack(tab)
  local ws = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.bo[b].filetype == queue.ENTRY_FILETYPE then
      ws[#ws + 1] = { win = w, buf = b, row = vim.api.nvim_win_get_position(w)[1] }
    end
  end
  table.sort(ws, function(a, b)
    return a.row < b.row
  end)
  return ws
end

local function press(buf, lhs)
  local want = vim.api.nvim_replace_termcodes(lhs, true, false, true)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if vim.api.nvim_replace_termcodes(m.lhs, true, false, true) == want and m.callback then
      return m.callback()
    end
  end
  error("no keymap " .. lhs .. " in buffer " .. buf)
end

---Headless nvim has no UI, so neither feedkeys nor nvim_input reaches the main
---loop where TextChanged is evaluated. Write the text and fire the event the way
---real typing would -- which is the wiring under test.
local function edit_entry(buf, text)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n"))
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
end

---A chat in its own tab, wired to the queue, with the chat's submits recorded.
local function open_chat()
  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()
  local chat_buf = vim.api.nvim_create_buf(false, true)
  vim.b[chat_buf].cc_tab_owner = tab
  vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), chat_buf)
  vim.api.nvim_buf_set_lines(chat_buf, 0, -1, false, { "## Me", "" })

  local submitted = {}
  local chat = {
    bufnr = chat_buf,
    adapter = { type = "omnigent", name = "omnigent" },
    submit = function()
      local lines = vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false)
      submitted[#submitted + 1] = lines[#lines]
      -- Emulate ready_for_input writing a fresh trailing `## Me`.
      vim.api.nvim_buf_set_lines(chat_buf, -1, -1, false, { "", "## Me", "" })
    end,
  }
  codecompanion.buf_get_chat = function(b)
    return b == chat_buf and chat or nil
  end

  queue.on_chat_opened(chat_buf)
  return { tab = tab, chat_bufnr = chat_buf, input = queue.bufnr(), submitted = submitted }
end

---Queue `msgs` through the input box. The chat must already be busy, or the
---first one would go out immediately instead of queueing.
local function enqueue(ctx, msgs)
  for _, msg in ipairs(msgs) do
    vim.api.nvim_buf_set_lines(ctx.input, 0, -1, false, { msg })
    press(ctx.input, keys().send)
  end
end

T["each queued message gets its own editable, named buffer"] = function()
  local ctx = open_chat()
  queue.on_request_started(ctx.chat_bufnr, 1)
  enqueue(ctx, { "first", "second", "third" })

  local stack = entry_stack(ctx.tab)
  h.eq(#stack, 3)
  h.eq(vim.bo[stack[1].buf].modifiable, true)
  h.is_true(vim.api.nvim_buf_get_name(stack[1].buf):match("cc%-queue://%d+") ~= nil)
  h.eq(vim.api.nvim_buf_get_lines(stack[1].buf, 0, -1, false)[1], "first")
  h.is_true(stack[1].row < stack[2].row and stack[2].row < stack[3].row)
  h.is_true(vim.wo[stack[1].win].winbar:find("»", 1, true) ~= nil)
end

T["yellow marks what will be sent, so the input box is never tinted"] = function()
  local ctx = open_chat()
  queue.on_request_started(ctx.chat_bufnr, 1)
  enqueue(ctx, { "first" })

  local stack = entry_stack(ctx.tab)
  h.is_true(vim.wo[stack[1].win].winhighlight:find("CCQueuedNormal", 1, true) ~= nil)
  -- The box holds the one thing that is NOT queued -- the next draft.
  h.eq(vim.wo[vim.fn.bufwinid(ctx.input)].winhighlight, "")
end

T["editing an entry holds it and everything queued after it"] = function()
  local ctx = open_chat()
  queue.on_request_started(ctx.chat_bufnr, 1)
  enqueue(ctx, { "first", "second", "third" })

  local stack = entry_stack(ctx.tab)
  edit_entry(stack[2].buf, "second EDITED")

  h.is_true(vim.wo[stack[2].win].winbar:find("✎", 1, true) ~= nil)
  h.is_true(vim.wo[stack[3].win].winbar:find("⏸", 1, true) ~= nil)
  h.is_true(vim.wo[stack[1].win].winbar:find("»", 1, true) ~= nil)

  h.is_true(vim.wo[stack[2].win].winhighlight:find("CCHeldNormal", 1, true) ~= nil)
  h.is_true(vim.wo[stack[3].win].winhighlight:find("CCHeldNormal", 1, true) ~= nil)
  h.is_true(vim.wo[stack[1].win].winhighlight:find("CCQueuedNormal", 1, true) ~= nil)
end

T["a clean head flushes past a later edit, but an edited head pauses"] = function()
  local ctx = open_chat()
  queue.on_request_started(ctx.chat_bufnr, 1)
  enqueue(ctx, { "first", "second" })
  edit_entry(entry_stack(ctx.tab)[2].buf, "second EDITED")

  queue.on_request_finished(ctx.chat_bufnr, 1, "success")
  queue.on_chat_done(ctx.chat_bufnr)
  h.eq(ctx.submitted[#ctx.submitted], "first")

  -- The head is now the entry being edited, so the queue stops.
  local before = #ctx.submitted
  queue.on_chat_done(ctx.chat_bufnr)
  h.eq(#ctx.submitted, before)
end

T["committing releases the hold and resumes an idle queue"] = function()
  local ctx = open_chat()
  queue.on_request_started(ctx.chat_bufnr, 1)
  enqueue(ctx, { "first", "second" })
  local stack = entry_stack(ctx.tab)
  edit_entry(stack[2].buf, "second EDITED")

  queue.on_request_finished(ctx.chat_bufnr, 1, "success")
  queue.on_chat_done(ctx.chat_bufnr)

  press(stack[2].buf, keys().commit)
  h.eq(ctx.submitted[#ctx.submitted], "second EDITED")
  h.eq(#entry_stack(ctx.tab), 0)
  h.eq(vim.api.nvim_buf_is_valid(stack[1].buf), false)
end

T["dropping an entry discards it without sending"] = function()
  local ctx = open_chat()
  queue.on_request_started(ctx.chat_bufnr, 1)
  enqueue(ctx, { "first" })

  press(entry_stack(ctx.tab)[1].buf, keys().drop)
  h.eq(#entry_stack(ctx.tab), 0)
  h.eq(#ctx.submitted, 0)
end

-- On a harness that cannot fold a mid-turn post into the running turn, the send
-- key must NOT post out of band -- it moves the message to the head of the queue
-- so it goes out through the ordinary submit path on the next flush.
T["send-next moves an entry to the head when the harness cannot steer"] = function()
  local ctx = open_chat() -- fake chat has no omnigent_session -> cannot steer
  queue.on_request_started(ctx.chat_bufnr, 1)
  enqueue(ctx, { "first", "second", "third" })

  press(entry_stack(ctx.tab)[3].buf, keys().steer)
  h.eq(#ctx.submitted, 0) -- nothing posted out of band

  local stack = entry_stack(ctx.tab)
  h.eq(vim.api.nvim_buf_get_lines(stack[1].buf, 0, -1, false)[1], "third")
  h.eq(#stack, 3)

  -- ...and it is what the next flush sends.
  queue.on_request_finished(ctx.chat_bufnr, 1, "success")
  queue.on_chat_done(ctx.chat_bufnr)
  h.eq(ctx.submitted[#ctx.submitted], "third")
end

T["send-next adopts an uncommitted edit before promoting"] = function()
  local ctx = open_chat()
  queue.on_request_started(ctx.chat_bufnr, 1)
  enqueue(ctx, { "first", "second" })

  local stack = entry_stack(ctx.tab)
  edit_entry(stack[2].buf, "second EDITED")
  press(stack[2].buf, keys().steer)

  queue.on_request_finished(ctx.chat_bufnr, 1, "success")
  queue.on_chat_done(ctx.chat_bufnr)
  h.eq(ctx.submitted[#ctx.submitted], "second EDITED")
end

T["send-next on an idle chat submits instead of queueing"] = function()
  local ctx = open_chat()
  queue.on_request_started(ctx.chat_bufnr, 1)
  enqueue(ctx, { "first" })
  queue.on_request_finished(ctx.chat_bufnr, 1, "success")

  -- Nothing is running, so there is no turn to steer into and nothing to wait
  -- for: it goes out now.
  press(entry_stack(ctx.tab)[1].buf, keys().steer)
  h.eq(ctx.submitted[#ctx.submitted], "first")
  h.eq(#entry_stack(ctx.tab), 0)
end

-- Reordering used to close every entry window and let the next sync rebuild the
-- stack, which flickered the whole column. The buffers move between the windows
-- that are already open instead.
T["promoting an entry reuses the open windows rather than rebuilding them"] = function()
  local ctx = open_chat()
  queue.on_request_started(ctx.chat_bufnr, 1)
  enqueue(ctx, { "first", "second", "third" })

  local before = entry_stack(ctx.tab)
  local win_ids = { before[1].win, before[2].win, before[3].win }

  press(before[3].buf, keys().steer)

  local after = entry_stack(ctx.tab)
  h.eq(#after, 3)
  -- Same three windows, in the same screen positions.
  h.eq({ after[1].win, after[2].win, after[3].win }, win_ids)
  -- ...now showing the reordered queue.
  h.eq(vim.api.nvim_buf_get_lines(after[1].buf, 0, -1, false)[1], "third")
  h.eq(vim.api.nvim_buf_get_lines(after[2].buf, 0, -1, false)[1], "first")
  h.eq(vim.api.nvim_buf_get_lines(after[3].buf, 0, -1, false)[1], "second")
end

-- An idle chat must still route through the queue: submitting the draft straight
-- past the queued entries showed nothing, so the message appeared to teleport to
-- the front of the transcript with no explanation.
T["send-next on an idle chat with a queue still shows the promotion"] = function()
  local ctx = open_chat()
  queue.on_request_started(ctx.chat_bufnr, 1)
  enqueue(ctx, { "first", "second" })
  queue.on_request_finished(ctx.chat_bufnr, 1, "success")

  vim.api.nvim_buf_set_lines(ctx.input, 0, -1, false, { "urgent" })
  press(ctx.input, keys().steer)

  h.eq(ctx.submitted[#ctx.submitted], "urgent")
  -- The two it jumped are still queued, in their original order.
  local stack = entry_stack(ctx.tab)
  h.eq(#stack, 2)
  h.eq(vim.api.nvim_buf_get_lines(stack[1].buf, 0, -1, false)[1], "first")
end

T["send-next from the input box puts the draft at the head"] = function()
  local ctx = open_chat()
  queue.on_request_started(ctx.chat_bufnr, 1)
  enqueue(ctx, { "first", "second" })

  vim.api.nvim_buf_set_lines(ctx.input, 0, -1, false, { "urgent" })
  press(ctx.input, keys().steer)
  h.eq(#ctx.submitted, 0)

  local stack = entry_stack(ctx.tab)
  h.eq(#stack, 3)
  h.eq(vim.api.nvim_buf_get_lines(stack[1].buf, 0, -1, false)[1], "urgent")
  h.eq(vim.api.nvim_buf_get_lines(ctx.input, 0, -1, false)[1], "")
end

T["hiding the chat keeps the queue and any uncommitted edit"] = function()
  local ctx = open_chat()
  queue.on_request_started(ctx.chat_bufnr, 1)
  enqueue(ctx, { "alpha", "beta" })
  edit_entry(entry_stack(ctx.tab)[2].buf, "beta EDITED")

  queue.on_chat_hidden(ctx.chat_bufnr)
  h.eq(#entry_stack(ctx.tab), 0)

  queue.on_chat_opened(ctx.chat_bufnr)
  local restored = entry_stack(ctx.tab)
  h.eq(#restored, 2)
  h.eq(vim.api.nvim_buf_get_lines(restored[2].buf, 0, -1, false)[1], "beta EDITED")
  h.is_true(vim.wo[restored[2].win].winbar:find("✎", 1, true) ~= nil)
end

return T
