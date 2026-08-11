-- Live check of the strategy fallback on a real claude-sdk session:
-- `control_event` is refused by the server (no summarisation model declared for
-- stock SDK agents), so the request must fall through to `slash_command` and
-- complete when the turn the slash command created ends.
--
--   nvim --headless --noplugin -u tests/omnigent/minimal_init.lua \
--     -c "luafile tests/omnigent/live_smoke_compaction_fallback.lua" -c "qa!"
local client = require("codecompanion.omnigent.client")
local session = require("codecompanion.omnigent.session")
local Observer = require("codecompanion.interactions.chat.omnigent.observer")
local compaction = require("codecompanion.interactions.chat.omnigent.compaction")
local fs = require("tests.omnigent.fake_server")

local function log(...)
  print("[fallback]", ...)
end

local URL = vim.env.OMNIGENT_URL or "http://127.0.0.1:6767"
local adapter = {
  type = "omnigent",
  url = URL,
  defaults = { agent = vim.env.OMNI_AGENT or "claude", host = "auto", workspace = "/tmp" },
  opts = { background_updates = true },
}

local phases = {}
vim.api.nvim_create_autocmd("User", {
  pattern = "CodeCompanionOmnigentCompaction",
  callback = function(args)
    phases[#phases + 1] = (args.data.phase or "?") .. "/" .. (args.data.strategy or "-")
  end,
})

local chat = fs.mock_chat(adapter)
local turns = 0
local s = session.new({ adapter = adapter, client = client.new({ url = URL }), callbacks = {} })

local created, cerr = s:create()
if not created then
  log("FAIL create:", vim.inspect(cerr))
  return
end
chat.omnigent_session = s
chat.omnigent_session_id = s.session_id

local observer = Observer.new(chat)
local wrapped = { handle_update = function(_, u)
  if u.kind == "turn_completed" then
    turns = turns + 1
  end
  observer:handle_update(u)
end }
s:set_observer(wrapped)
s:start_stream()
log("session:", s.session_id)
vim.wait(4000, function() return false end, 200)

local function turn(p)
  local before = turns
  s:post_message(p)
  return vim.wait(240000, function() return turns > before end, 200)
end

log("seed turn 1:", tostring(turn("List 8 common HTTP status codes, one per line.")))
log("seed turn 2:", tostring(turn("Now list 8 common Unix signals, one per line.")))

local before = turns
log("--- compaction.request (expect control_event -> 4xx -> slash_command) ---")
local ok, err = compaction.request(chat)
log("request accepted:", tostring(ok), err and vim.inspect(err) or "")

vim.wait(180000, function()
  return not compaction.in_flight(chat)
end, 250)

log("phases:", vim.inspect(phases))
log("turn fired for the slash command:", tostring(turns > before))
log("indicator cleared:", tostring(not compaction.in_flight(chat)))
local note = vim.tbl_filter(function(b)
  return type(b.content) == "string" and b.content:find("Compaction requested", 1, true) ~= nil
end, chat.buf_calls)
log("marker written:", #note == 1 and note[1].content:gsub("\n", " | ") or "NO")

-- The agent must NOT have answered "/compact" as if it were a prompt.
local replied = vim.tbl_filter(function(b)
  return b.type == "llm_msg" and type(b.content) == "string" and #b.content > 0
end, chat.buf_calls)
log("assistant output during the compact turn:", #replied > 0 and "SOME (check above)" or "none (intercepted)")

s:stop_stream()
s.client:post_event(s.session_id, { type = "stop_session", data = vim.empty_dict() })
log(#note == 1 and "PASS" or "CHECK ABOVE")
