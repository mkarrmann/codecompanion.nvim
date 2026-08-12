-- Live proof that a steer is folded INTO the running turn rather than admitted
-- as a follow-up. NOT a unit test: it creates a real session and runs a real
-- (deliberately trivial) turn. Run with:
--   nvim --headless --noplugin -u tests/omnigent/minimal_init.lua \
--     -c "luafile tests/omnigent/live_smoke_steer.lua" -c "qa!"
--
-- This is the assertion the fake-server tests cannot make. The runner forwards a
-- mid-turn POST only when `_can_forward` holds -- crucially, only once
-- `response.created` has put the conversation in `_live_response_id`. A client
-- that posts a moment earlier gets its message buffered and served as the NEXT
-- turn, which looks identical from the outside until you count response ids.
--
-- So the test is: how many responses did two messages produce?
--   1 response  -> the steer was injected (what we want)
--   2 responses -> it was admitted as a follow-up turn (the bug)
local session = require("codecompanion.omnigent.session")

local function log(...)
  print("[steer-smoke]", ...)
end

local URL = vim.env.OMNI_URL or "http://127.0.0.1:6767"
local AGENT = vim.env.OMNI_AGENT or "claude"

local adapter = {
  type = "omnigent",
  url = URL,
  -- /tmp on purpose: the prompt asks for no work, but a stray tool call must not
  -- land in a real checkout.
  defaults = { agent = AGENT, host = "auto", workspace = "/tmp" },
  opts = {},
}

local s = session.new({ adapter = adapter })

-- Every response id we see, in order, plus the assistant text per response.
local responses, order = {}, {}
local steered_seen, turn_ends = false, 0

local function note_response(rid)
  if rid and not responses[rid] then
    responses[rid] = ""
    order[#order + 1] = rid
  end
end

s.callbacks.on_update = function(u)
  if u.response_id then
    note_response(u.response_id)
  end
  if u.kind == "message_delta" and u.response_id then
    responses[u.response_id] = u.text or ((responses[u.response_id] or "") .. (u.delta or ""))
  elseif u.kind == "input_consumed" then
    local text = u.message and u.message.content and u.message.content[1] and u.message.content[1].text
    log("input consumed:", vim.inspect(text and text:sub(1, 40)))
    if text and text:find("BANANA", 1, true) then
      steered_seen = true
    end
  elseif u.kind == "turn_completed" or u.kind == "turn_failed" or u.kind == "turn_cancelled" then
    turn_ends = turn_ends + 1
    log("turn end:", u.kind, u.response_id)
  end
end
s.callbacks.on_error = function(e)
  log("ERROR", vim.inspect(e))
end

local created, cerr = s:create()
if not created then
  log("FAIL create:", vim.inspect(cerr))
  return
end
log("session:", s.session_id, "harness:", tostring(s.harness))

s:start_stream()

-- A turn long enough that there is a live response to steer into, and slow
-- enough that the steer lands mid-flight.
s:post_message("Count slowly from 1 to 30, one number per line. No commentary.")

-- Wait for the gate to open rather than sleeping a guessed interval: this is
-- precisely the condition the client-side fix waits on. Native harnesses drive
-- their turns differently, so fall back to "any response is open" rather than
-- reporting a false negative when only the SDK-shaped gate fails to trip.
local opened = vim.wait(60000, function()
  return s:steerable_now()
end, 100)
if not opened then
  log("gate never opened; falling back to any live response")
  opened = vim.wait(30000, function()
    return s.reducer.current_response_id ~= nil
  end, 100)
end
log("steerable:", tostring(s:steerable_now()), "live response:", tostring(s.reducer.current_response_id))
if not s.reducer.current_response_id then
  log("INCONCLUSIVE: no live response ever opened; nothing to steer into")
  s:stop_stream()
  return
end
local first_response = s.reducer.current_response_id

s:post_message("Also say the word BANANA somewhere in your reply.")
log("steer posted")

vim.wait(180000, function()
  return turn_ends >= 1 and not s:busy()
end, 250)
-- Let a second turn appear if the server was going to start one.
vim.wait(15000, function()
  return #order > 1
end, 250)

s:stop_stream()

-- Verdict by ATTRIBUTION, not by counting ids: native harnesses mint several id
-- namespaces for one turn (`resp_*` ack, `codex:...:agentMessage:*` stream,
-- `codex_<uuid>` turn), so "how many response ids appeared" says nothing. The
-- question is whether the steered content came back inside the response that was
-- already streaming when it was sent.
local in_first = (responses[first_response] or ""):find("BANANA", 1, true) ~= nil
local anywhere = table.concat(vim.tbl_values(responses), "\n"):find("BANANA", 1, true) ~= nil

log("response ids seen:", #order, vim.inspect(order))
log("turn_completed count:", turn_ends)
log("steered message consumed:", tostring(steered_seen))
log("BANANA in the live response:", tostring(in_first))
log("BANANA anywhere:", tostring(anywhere))

if in_first then
  log("PASS: steer folded INTO the turn that was already running")
elseif anywhere then
  log("PARTIAL: steer was answered, but in a later turn -- not injected")
elseif steered_seen then
  log("FAIL: steer was delivered but never answered in this window")
else
  log("INCONCLUSIVE: steer never reached the agent")
end
