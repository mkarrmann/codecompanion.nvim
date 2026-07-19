local h = require("tests.helpers")
local new_set = MiniTest.new_set

local Observer = require("codecompanion.interactions.chat.omnigent.observer")
local fs = require("tests.omnigent.fake_server")

local ADAPTER = { type = "omnigent", url = "http://x", opts = { background_updates = true } }

local T = new_set()

local function new_observer()
  local chat = fs.mock_chat(ADAPTER)
  chat.omnigent_session_id = "conv_bg"
  return Observer.new(chat), chat
end

T["renders a background turn's deltas as suffixes, with one header"] = function()
  local obs, chat = new_observer()
  obs:handle_update({ kind = "turn_started", response_id = "__live__", background = true })
  obs:handle_update({ kind = "message_delta", response_id = "__live__", delta = "Hello ", text = "Hello " })
  obs:handle_update({ kind = "message_delta", response_id = "__live__", delta = "world", text = "Hello world" })

  h.eq(fs.rendered_text(chat, "llm_msg"), "Hello world")
  -- Exactly one background header written.
  local headers = vim.tbl_filter(function(b)
    return b.type == "sys_msg" and b.content:find("background activity", 1, true) ~= nil
  end, chat.buf_calls)
  h.eq(#headers, 1)
  h.eq(obs:has_partial(), true)
end

T["finalize commits the turn to the transcript and clears partial"] = function()
  local obs, chat = new_observer()
  obs:handle_update({ kind = "message_delta", response_id = "__live__", delta = "done.", text = "done." })
  obs:handle_update({ kind = "turn_completed", response_id = "resp_real" })

  h.eq(obs:has_partial(), false)
  local committed = vim.tbl_filter(function(m)
    return m.role == "llm" and m.content == "done."
  end, chat.messages)
  h.eq(#committed, 1)
  h.eq(committed[1]._meta.sent, true)
  h.eq(committed[1]._meta.omnigent_background, true)
end

T["turn_started during an open partial is a continuation (no re-render)"] = function()
  -- Simulates a reconnect: partial shown, then a fresh turn_started retargets the
  -- id but must NOT reset what we've already rendered.
  local obs, chat = new_observer()
  obs:handle_update({ kind = "message_delta", response_id = "__live__", delta = "Hello", text = "Hello" })
  obs:handle_update({ kind = "turn_started", response_id = "resp_new", background = true })
  obs:handle_update({ kind = "message_delta", response_id = "resp_new", delta = " world", text = "Hello world" })

  h.eq(fs.rendered_text(chat, "llm_msg"), "Hello world") -- not "HelloHello world"
end

T["content-dedup: a replayed full message renders only the new suffix"] = function()
  local obs, chat = new_observer()
  obs:handle_update({ kind = "message_delta", response_id = "__live__", delta = "Hel", text = "Hel" })
  -- Replay re-sends the whole in-flight message (reset_inflight rebuilds text).
  obs:handle_update({ kind = "message_delta", response_id = "__live__", delta = "Hello", text = "Hello" })
  h.eq(fs.rendered_text(chat, "llm_msg"), "Hello")
end

T["external user message renders as a user row and persists"] = function()
  local obs, chat = new_observer()
  obs:handle_update({
    kind = "item_committed",
    item_type = "message",
    role = "user",
    text = "poke from elsewhere",
    item_id = "msg_u",
  })
  local user_rows = vim.tbl_filter(function(b)
    return b.type == "user_msg"
  end, chat.buf_calls)
  h.eq(#user_rows, 1)
  h.eq(user_rows[1].content, "poke from elsewhere")
end

T["committed-only native assistant messages render and persist"] = function()
  local obs, chat = new_observer()
  obs:handle_update({
    kind = "item_committed",
    item_type = "message",
    role = "assistant",
    text = "claude answer",
    text_streamed = false,
    item_id = "msg_a",
  })
  h.eq(fs.rendered_text(chat, "llm_msg"), "claude answer")
  obs:handle_update({ kind = "turn_completed", response_id = "resp_claude" })
  local assistant = vim.tbl_filter(function(message)
    return message.content == "claude answer"
  end, chat.messages)
  h.eq(#assistant, 1)
end

T["background failure surfaces a warning and clears partial"] = function()
  local obs, chat = new_observer()
  obs:handle_update({ kind = "message_delta", response_id = "__live__", delta = "partial", text = "partial" })
  obs:handle_update({ kind = "turn_failed", response_id = "__live__", error = { message = "kaboom" } })
  h.eq(obs:has_partial(), false)
  local warned = vim.tbl_filter(function(b)
    return b.content and b.content:find("kaboom", 1, true) ~= nil
  end, chat.buf_calls)
  h.eq(#warned, 1)
end

T["restores the input anchor after a background turn completes"] = function()
  -- The bug: after out-of-band background writes, chat.header_line is stale and
  -- there's no trailing ## Me, so the user's next submit is dropped. The observer
  -- must call reset_input_anchor() once the turn finishes.
  local obs, chat = new_observer()
  obs:handle_update({ kind = "message_delta", response_id = "__live__", delta = "hi", text = "hi" })
  h.eq(chat.input_anchor_resets, 0) -- not while mid-stream
  obs:handle_update({ kind = "turn_completed", response_id = "resp_x" })
  h.is_true(chat.input_anchor_resets >= 1) -- restored on completion
end

T["restores the input anchor after a standalone note (no turn boundary)"] = function()
  local obs, chat = new_observer()
  -- A tool-call row with no open turn must still leave a usable input anchor.
  obs:handle_update({ kind = "item_committed", item_type = "function_call", item = { name = "sys_read_inbox" } })
  h.is_true(chat.input_anchor_resets >= 1)
end

T["system-injected [System:...] user items render as a note, not a ## Me turn"] = function()
  local obs, chat = new_observer()
  obs:handle_update({
    kind = "item_committed",
    item_type = "message",
    role = "user",
    text = "[System: sub-agent claude/who-are-you finished (completed) — 1 result waiting]",
    item_id = "msg_sys",
  })
  -- No user (## Me) buffer row, and NOT added to the transcript as a user message.
  local user_rows = vim.tbl_filter(function(b)
    return b.type == "user_msg"
  end, chat.buf_calls)
  h.eq(#user_rows, 0)
  local user_msgs = vim.tbl_filter(function(m)
    return m.role == "user"
  end, chat.messages)
  h.eq(#user_msgs, 0)
  -- It IS surfaced as a compact note so the user still has visibility.
  local notes = vim.tbl_filter(function(b)
    return b.type == "sys_msg" and b.content:find("sub-agent", 1, true) ~= nil
  end, chat.buf_calls)
  h.eq(#notes, 1)
end

T["genuine external user message still renders as a user turn"] = function()
  local obs, chat = new_observer()
  obs:handle_update({
    kind = "item_committed",
    item_type = "message",
    role = "user",
    text = "poke from another client",
    item_id = "msg_u",
  })
  local user_rows = vim.tbl_filter(function(b)
    return b.type == "user_msg"
  end, chat.buf_calls)
  h.eq(#user_rows, 1)
end

T["skips background rendering while the user is composing input"] = function()
  local obs, chat = new_observer()
  chat.pending_input = true -- user is mid-type
  obs:handle_update({ kind = "message_delta", response_id = "__live__", delta = "hi", text = "hi" })
  -- Nothing written to the buffer, and the input anchor is left untouched.
  h.eq(#chat.buf_calls, 0)
  h.eq(chat.input_anchor_resets, 0)
  h.eq(obs:has_partial(), false)
end

T["fires ChatOmnigentWakeup and ChatOmnigentBackgroundTurn"] = function()
  local obs = select(1, new_observer())
  local seen = {}
  local group = vim.api.nvim_create_augroup("omni_obs_evt", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "CodeCompanionChatOmnigentWakeup", "CodeCompanionChatOmnigentBackgroundTurn" },
    callback = function(a)
      seen[a.match] = (seen[a.match] or 0) + 1
    end,
  })
  obs:handle_update({ kind = "message_delta", response_id = "__live__", delta = "hi", text = "hi" })
  obs:handle_update({ kind = "turn_completed", response_id = "resp_x" })
  vim.api.nvim_del_augroup_by_id(group)

  h.eq(seen["CodeCompanionChatOmnigentWakeup"], 1)
  h.eq(seen["CodeCompanionChatOmnigentBackgroundTurn"], 1)
end

return T
