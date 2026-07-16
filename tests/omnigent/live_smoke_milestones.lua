-- Live validation of the M3/M4/M5/M6 wiring against a running omnigent server.
-- Run: OMNI_AGENT=polly nvim --headless --noplugin -u tests/omnigent/minimal_init.lua \
--        -c "luafile tests/omnigent/live_smoke_milestones.lua" -c "qa!"
local Client = require("codecompanion.omnigent.client")
local Session = require("codecompanion.omnigent.session")
local sessions_lib = require("codecompanion.interactions.chat.omnigent.sessions")

local URL = vim.env.OMNIGENT_URL or "http://127.0.0.1:6767"
local AGENT = vim.env.OMNI_AGENT or "polly"

local function p(...)
  print("[live]", ...)
end

-- ---- M3: list + format sessions --------------------------------------------
local client = Client.new({ url = URL })
local list, err = client:list_sessions({ limit = 20 })
assert(list, "list_sessions failed: " .. (err and err.message or "?"))
p("M3 list_sessions:", #list, "sessions")
local ranked = sessions_lib.by_recency(sessions_lib.active(list))
if ranked[1] then
  p("M3 format_summary:", sessions_lib.format_summary(ranked[1], { now = os.time() }))
end

local host_id = client:resolve_host("auto")
p("host auto ->", tostring(host_id))

-- ---- M4/M6: create + observer-backed stream + controller meta --------------
local adapter = {
  type = "omnigent",
  url = URL,
  defaults = { agent = AGENT, host = "auto", workspace = "auto" },
  opts = { background_updates = true, stream_heartbeat_timeout = 0 },
}
local session = Session.new({ adapter = adapter })

-- A tiny recording observer stands in for the chat observer.
local rendered = {}
session:set_observer({
  handle_update = function(_, u)
    if u.kind == "message_delta" then
      rendered[#rendered + 1] = u.delta
    end
  end,
  has_partial = function()
    return false
  end,
  reconcile_item = function() end,
})

local created, cerr = session:create()
assert(created, "create failed: " .. (cerr and cerr.message or "?"))
p("M4 created session:", session.session_id, "host:", tostring(session.host_id))

-- Foreground turn: bind a foreground callback (takes precedence over observer).
local fg = {}
local done = false
session.callbacks.on_update = function(u)
  if u.kind == "message_delta" then
    fg[#fg + 1] = u.delta
  elseif u.kind == "turn_completed" or u.kind == "turn_failed" or u.kind == "interrupted" then
    done = true
  end
end
session.callbacks.on_stream_end = function()
  done = true
end

session:start_stream()
session:post_message("Reply with exactly: ok")

vim.wait(30000, function()
  return done
end, 100)

p("M4 foreground streamed:", vim.inspect(table.concat(fg)))
p("M4 observer saw (should be empty during foreground):", #rendered)

-- ---- M6: controller.session_meta on the live session -----------------------
local controller = require("codecompanion.interactions.chat.omnigent.controller")
local meta = controller.session_meta({ omnigent_session = session })
p("M6 session_meta:", vim.inspect({
  session_id = meta.session_id,
  status = meta.status,
  streaming = meta.streaming,
  model = meta.model,
}))

session:stop_stream()
p("DONE. foreground_text_nonempty =", tostring(#fg > 0))
