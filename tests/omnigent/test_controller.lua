local h = require("tests.helpers")
local new_set = MiniTest.new_set

local sessionful = require("codecompanion.interactions.chat.sessionful")
local controller = require("codecompanion.interactions.chat.omnigent.controller")

local T = new_set()

T["sessionful registry resolves omnigent only"] = function()
  h.is_true(sessionful.is_sessionful({ adapter = { type = "omnigent" } }))
  h.eq(sessionful.is_sessionful({ adapter = { type = "acp" } }), false)
  h.eq(sessionful.is_sessionful({ adapter = { type = "http" } }), false)
  h.eq(sessionful.for_chat({ adapter = { type = "omnigent" } }), controller)
  h.eq(sessionful.for_chat({ adapter = { type = "acp" } }), nil)
end

T["session_meta reflects the session, nil when absent"] = function()
  h.eq(controller.session_meta({ omnigent_session = nil }), nil)

  local chat = {
    omnigent_session = {
      session_id = "conv_1",
      agent_id = "ag_1",
      host_id = "host_1",
      workspace = "/w",
      status = "idle",
      reasoning_effort = "high",
      usage = { context_tokens = 5 },
      model_override = "opus",
      pending_elicitations = { e1 = true, e2 = true },
      streaming = function()
        return true
      end,
    },
  }
  local m = controller.session_meta(chat)
  h.eq(m.session_id, "conv_1")
  h.eq(m.host_id, "host_1")
  h.eq(m.status, "idle")
  h.eq(m.model, "opus")
  h.eq(m.pending_elicitations, 2)
  h.eq(m.streaming, true)
end

T["close stops the stream (no-op without a session)"] = function()
  local stopped = false
  controller.close({ omnigent_session = { stop_stream = function()
    stopped = true
  end } })
  h.eq(stopped, true)
  -- must not throw without a session
  controller.close({})
end

T["ensure_session delegates without binding a foreground request"] = function()
  local handler_module = "codecompanion.interactions.chat.omnigent.handler"
  local original = package.loaded[handler_module]
  local received
  package.loaded[handler_module] = {
    new = function()
      return {
        ensure_session = function(_, opts)
          received = opts
          return true
        end,
      }
    end,
  }
  local ok, err = pcall(function()
    h.eq(controller.ensure_session({}), true)
    h.eq(received.foreground, false)
  end)
  package.loaded[handler_module] = original
  if not ok then
    error(err)
  end
end

return T
