-- Live end-to-end smoke for context compaction against a running omnigent server.
-- NOT a unit test: it creates a real (cheap) throwaway session, runs one short
-- turn so there is something to compact, then requests compaction and asserts the
-- `response.compaction.*` events reach the reducer as compaction_* updates.
--
--   OMNI_AGENT=polly nvim --headless --noplugin -u tests/omnigent/minimal_init.lua \
--     -c "luafile tests/omnigent/live_smoke_compaction.lua" -c "qa!"
local client = require("codecompanion.omnigent.client")
local session = require("codecompanion.omnigent.session")

local function log(...)
  print("[compact-smoke]", ...)
end

local URL = vim.env.OMNIGENT_URL or "http://127.0.0.1:6767"
local c = client.new({ url = URL })

local adapter = {
  type = "omnigent",
  url = URL,
  defaults = { agent = vim.env.OMNI_AGENT or "polly", host = "auto", workspace = "/tmp" },
  opts = {},
}

local seen = {}
local turn_done = false
local compaction_terminal = nil
local completed_update = nil

local s = session.new({
  adapter = adapter,
  client = c,
  callbacks = {
    on_update = function(u)
      seen[u.kind] = (seen[u.kind] or 0) + 1
      if u.kind == "turn_completed" then
        turn_done = true
      elseif u.kind == "compaction_completed" then
        compaction_terminal = "completed"
        completed_update = u
      elseif u.kind == "compaction_failed" then
        compaction_terminal = "failed"
      end
    end,
    on_error = function(e)
      log("stream error:", vim.inspect(e))
    end,
  },
})

local created, cerr = s:create()
if not created then
  log("FAIL create:", vim.inspect(cerr))
  return
end
log("session:", s.session_id, "agent:", s.agent_name or s.agent_id)

s:start_stream()
s:post_message("Reply with exactly: ready")
vim.wait(120000, function()
  return turn_done
end, 200)
log("turn_completed:", turn_done)

-- Guard check: refuse while the session is mid-turn.
s.status = "running"
local refused, rerr = s:compact()
log("busy guard refused:", tostring(refused == false), rerr and rerr.message or "")
s.status = "idle"

local accepted, aerr = s:compact({ timeout = 300000 }, function(ok, err)
  log("POST outcome:", tostring(ok), err and vim.inspect(err) or "")
end)
if not accepted then
  log("FAIL compact not accepted:", vim.inspect(aerr))
  return
end

vim.wait(300000, function()
  return compaction_terminal ~= nil
end, 250)

log("terminal:", tostring(compaction_terminal))
if completed_update then
  log("total_tokens:", tostring(completed_update.total_tokens))
  log("usage.context_tokens:", tostring(completed_update.usage and completed_update.usage.context_tokens))
  log("session.usage.context_tokens:", tostring(s.usage and s.usage.context_tokens))
end
log("kinds:", vim.inspect(seen))

-- The durable transcript should now carry a compaction item that resume renders.
local items = c:list_items(s.session_id)
local compaction_items = vim.tbl_filter(function(i)
  return i.type == "compaction"
end, items or {})
log("durable compaction items:", #compaction_items)
if compaction_items[1] then
  local render = require("codecompanion.interactions.chat.omnigent.render")
  local msg = render.durable_item_to_message(compaction_items[1])
  log("resume marker:", (msg and msg.content or ""):gsub("\n", " | "):sub(1, 200))
end

s:stop_stream()
log(compaction_terminal == "completed" and "PASS" or "CHECK ABOVE")
