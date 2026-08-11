-- Live end-to-end render check for compaction, with NO LLM cost.
--
-- The server republishes an `external_compaction_status` event (the channel the
-- native forwarders use to report a terminal-observed compaction) as the standard
-- `response.compaction.*` SSE. Posting those directly therefore drives the REAL
-- wire path -- server -> SSE -> sse.lua -> reducer -> session state -> observer ->
-- compaction module -> chat marker -- without a runner, a turn, or a token spent.
--
-- It does NOT prove a harness emits these (that is read from the emitters:
-- claude_sdk_executor.py yields CompactionComplete on the PreCompact hook, and the
-- native forwarders post external_compaction_status). It proves everything on the
-- client side of the wire.
--
--   nvim --headless --noplugin -u tests/omnigent/minimal_init.lua \
--     -c "luafile tests/omnigent/live_smoke_compaction_render.lua" -c "qa!"
local client = require("codecompanion.omnigent.client")
local session = require("codecompanion.omnigent.session")
local Observer = require("codecompanion.interactions.chat.omnigent.observer")
local compaction = require("codecompanion.interactions.chat.omnigent.compaction")
local fs = require("tests.omnigent.fake_server")

local function log(...)
  print("[render-smoke]", ...)
end

local URL = vim.env.OMNIGENT_URL or "http://127.0.0.1:6767"
local c = client.new({ url = URL })
local adapter = {
  type = "omnigent",
  url = URL,
  defaults = { agent = vim.env.OMNI_AGENT or "claude", host = "auto", workspace = "/tmp" },
  opts = { background_updates = true },
}

local chat = fs.mock_chat(adapter)
local phases = {}
vim.api.nvim_create_autocmd("User", {
  pattern = "CodeCompanionOmnigentCompaction",
  callback = function(args)
    phases[#phases + 1] = args.data.phase
  end,
})
local usage_events = {}
vim.api.nvim_create_autocmd("User", {
  pattern = "CodeCompanionOmnigentUsage",
  callback = function(args)
    usage_events[#usage_events + 1] = args.data.usage
  end,
})

local s = session.new({ adapter = adapter, client = c, callbacks = {} })
local created, cerr = s:create()
if not created then
  log("FAIL create:", vim.inspect(cerr))
  return
end
chat.omnigent_session = s
chat.omnigent_session_id = s.session_id
s:set_observer(Observer.new(chat))
s:start_stream()
log("session:", s.session_id, "(no turn sent -- zero LLM cost)")

local function post(status)
  local _, err = c:post_event(s.session_id, {
    type = "external_compaction_status",
    data = { status = status },
  })
  log("posted " .. status .. ":", err and ("ERR " .. vim.inspect(err)) or "ok")
end

-- Let the SSE connection actually establish. `start_stream` returns as soon as
-- the curl handle is spawned, so posting immediately races the subscription and
-- the event is published to nobody.
vim.wait(5000, function()
  return false
end, 250)

post("in_progress")
vim.wait(15000, function()
  return compaction.in_flight(chat)
end, 100)
log("indicator running after in_progress:", tostring(compaction.in_flight(chat)))

post("completed")
vim.wait(20000, function()
  return not compaction.in_flight(chat) and #phases > 0 and phases[#phases] == "completed"
end, 100)

local marker
for _, b in ipairs(chat.buf_calls) do
  if type(b.content) == "string" and b.content:find("Context compacted", 1, true) then
    marker = b.content
  end
end

log("phases fired:", vim.inspect(phases))
log("indicator cleared:", tostring(not compaction.in_flight(chat)))
log("marker rendered:", marker and ("yes -> " .. marker:gsub("\n", " | ")) or "NO")
log("usage events:", #usage_events)
log("session.usage:", vim.inspect(s.usage))

compaction.cancel(chat)
s:stop_stream()
c:post_event(s.session_id, { type = "stop_session", data = vim.empty_dict() })

local pass = marker ~= nil and phases[#phases] == "completed"
log(pass and "PASS" or "FAIL")
