local h = require("tests.helpers")
local new_set = MiniTest.new_set

local approval = require("codecompanion.interactions.chat.helpers.approval_prompt")
local elicit = require("codecompanion.interactions.chat.omnigent.elicitation")

-- The "no id" case deliberately hits log:error; silence it for clean output.
require("codecompanion.utils.log").error = function() end

local T = new_set()

---@param opts? table { hold?: boolean } hold => the POST stays in flight until
---  `session.release()` is called, mimicking a slow server.
local function fake_session(opts)
  opts = opts or {}
  return {
    pending_elicitations = { e1 = true },
    resolved = nil,
    resolve_elicitation_async = function(self, eid, result, callback)
      self.resolved = { eid = eid, result = result }
      local answer = function()
        callback({}) -- success
      end
      if opts.hold then
        self.release = answer
      else
        answer()
      end
      return { stop = function() end }
    end,
  }
end

-- Patch approval_prompt.request to auto-select the choice with keymap-index `pick`
-- (1=accept, 2=decline, 3=cancel), returning the module to its original after.
local function with_auto_pick(pick, fn)
  local orig = approval.request
  approval.request = function(_, opts)
    opts.choices[pick].callback()
    return function() end
  end
  local ok, err = pcall(fn)
  approval.request = orig
  if not ok then
    error(err)
  end
end

T["message_of / schema_of parse MCP params"] = function()
  h.eq(elicit.message_of({ message = "Proceed?" }), "Proceed?")
  h.eq(elicit.message_of(nil), "Agent requested input")
  h.eq(elicit.schema_of({ message = "x" }), nil)
  local s = elicit.schema_of({ requestedSchema = { type = "object", properties = { a = {} } } })
  h.is_true(s ~= nil and s.properties.a ~= nil)
end

T["collect_fields prompts in order and coerces types"] = function()
  local answers = { name = "Bob", age = "42", ok = "yes" }
  local orig = vim.ui.input
  vim.ui.input = function(o, cb)
    for k, v in pairs(answers) do
      if o.prompt:find(k, 1, true) then
        return cb(v)
      end
    end
    cb(nil)
  end
  local got
  elicit.collect_fields({
    properties = { name = { type = "string" }, age = { type = "integer" }, ok = { type = "boolean" } },
    required = { "name" },
  }, function(content)
    got = content
  end)
  vim.ui.input = orig
  h.eq(got.name, "Bob")
  h.eq(got.age, 42)
  h.eq(got.ok, true)
end

T["accept (no schema) resolves with action=accept and clears pending"] = function()
  local session = fake_session()
  with_auto_pick(1, function()
    elicit.handle({ bufnr = 0 }, session, { elicitation_id = "e1", params = { message = "ok?" } })
  end)
  h.eq(session.resolved.eid, "e1")
  h.eq(session.resolved.result.action, "accept")
  h.eq(session.resolved.result.content, nil)
  h.eq(session.pending_elicitations.e1, nil)
end

T["accept (with schema) resolves accept + collected content"] = function()
  local session = fake_session()
  local orig = vim.ui.input
  vim.ui.input = function(o, cb)
    cb("Bob")
  end
  with_auto_pick(1, function()
    elicit.handle({ bufnr = 0 }, session, {
      elicitation_id = "e1",
      params = { message = "name?", requestedSchema = { properties = { name = { type = "string" } } } },
    })
  end)
  vim.ui.input = orig
  h.eq(session.resolved.result.action, "accept")
  h.eq(session.resolved.result.content.name, "Bob")
end

T["decline and cancel map to the right MCP actions"] = function()
  local s1 = fake_session()
  with_auto_pick(2, function()
    elicit.handle({ bufnr = 0 }, s1, { elicitation_id = "e1", params = {} })
  end)
  h.eq(s1.resolved.result.action, "decline")

  local s2 = fake_session()
  with_auto_pick(3, function()
    elicit.handle({ bufnr = 0 }, s2, { elicitation_id = "e1", params = {} })
  end)
  h.eq(s2.resolved.result.action, "cancel")
end

T["approving does not block on the server's answer"] = function()
  -- The regression this guards: approval resolved through the SYNC transport, so
  -- every accept/deny froze nvim's main thread for the whole round trip -- and
  -- that fires once per gated tool call, the busiest REST path in a session.
  local session = fake_session({ hold = true })
  with_auto_pick(1, function()
    elicit.handle({ bufnr = 0 }, session, { elicitation_id = "e1", params = { message = "ok?" } })
  end)

  -- Returned with the resolve still outstanding, and the prompt is already
  -- retired so a replayed request can't ask twice while it is in flight.
  h.eq(type(session.release), "function")
  h.eq(session.resolved.result.action, "accept")
  h.eq(session.pending_elicitations.e1, nil)

  session.release()
end

T["a failed resolve reports without throwing"] = function()
  local notified
  local utils = require("codecompanion.utils")
  local orig = utils.notify
  utils.notify = function(msg)
    notified = msg
  end
  local session = fake_session()
  session.resolve_elicitation_async = function(_, _, _, callback)
    callback(nil, { message = "boom" })
  end
  local ok, err = pcall(function()
    with_auto_pick(1, function()
      elicit.handle({ bufnr = 0 }, session, { elicitation_id = "e1", params = {} })
    end)
  end)
  utils.notify = orig
  if not ok then
    error(err)
  end
  h.is_true(notified ~= nil and notified:find("failed to resolve", 1, true) ~= nil)
end

T["handle without an id does not throw"] = function()
  local session = fake_session()
  -- No approval.request patch needed: it returns before presenting.
  elicit.handle({ bufnr = 0 }, session, { params = {} })
  h.eq(session.resolved, nil)
end

return T
