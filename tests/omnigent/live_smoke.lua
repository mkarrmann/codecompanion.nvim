-- Live end-to-end smoke against a running omnigent server (127.0.0.1:6767).
-- NOT a unit test: it creates a real (cheap) session and exercises the real
-- REST + SSE transport. Run with:
--   nvim --headless --noplugin -u tests/omnigent/minimal_init.lua \
--     -c "luafile tests/omnigent/live_smoke.lua" -c "qa!"
local client = require("codecompanion.omnigent.client")
local session = require("codecompanion.omnigent.session")

local function log(...)
  print("[smoke]", ...)
end

local URL = "http://127.0.0.1:6767"
local c = client.new({ url = URL })

local agents, aerr = c:list_agents()
if not agents then
  log("FAIL list_agents:", vim.inspect(aerr))
  return
end
log("agents:", #agents)

local hosts, herr = c:list_hosts()
if not hosts then
  log("FAIL list_hosts:", vim.inspect(herr))
  return
end
log("hosts:", #hosts)

local host_id, rerr = c:resolve_host("auto", { hosts = hosts })
log("resolve_host(auto) ->", host_id or ("nil: " .. vim.inspect(rerr)))

local adapter = {
  type = "omnigent",
  url = URL,
  defaults = { agent = vim.env.OMNI_AGENT or "claude-native-ui", host = "auto", workspace = "/tmp" },
  opts = {},
}

local completed, failed = false, nil
local deltas = {}
local kinds = {}
local s = session.new({
  adapter = adapter,
  callbacks = {
    on_update = function(u)
      kinds[u.kind] = (kinds[u.kind] or 0) + 1
      if u.kind == "message_delta" then
        deltas[#deltas + 1] = u.delta
      elseif u.kind == "turn_completed" then
        completed = true
      elseif u.kind == "turn_failed" or u.kind == "error" then
        failed = u.error
        completed = true
      end
    end,
  },
})

local sess, cerr = s:create()
if not sess then
  log("FAIL create:", vim.inspect(cerr))
  return
end
log("created:", s.session_id, "| status:", s.status, "| host:", s.host_id, "| workspace:", s.workspace)

s:start_stream()
s:post_message("Reply with exactly the word: ok")
log("posted; waiting for completion (up to 90s)...")
vim.wait(90000, function()
  return completed
end, 250)

log("completed:", completed, "| deltas:", vim.inspect(table.concat(deltas)))
log("event kinds seen:", vim.inspect(kinds))
if failed then
  log("turn error:", vim.inspect(failed))
end

s:stop_stream()
log("DONE")
