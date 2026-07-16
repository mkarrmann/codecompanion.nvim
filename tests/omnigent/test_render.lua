local h = require("tests.helpers")
local new_set = MiniTest.new_set

local render = require("codecompanion.interactions.chat.omnigent.render")

local T = new_set()

local function read_json(name)
  return vim.json.decode(table.concat(vim.fn.readfile("tests/stubs/omnigent/" .. name), "\n"))
end

T["maps user and assistant messages"] = function()
  local user = render.durable_item_to_message({
    type = "message",
    role = "user",
    content = { { type = "input_text", text = "hello" } },
  })
  h.eq(user.role, "user")
  h.eq(user.content, "hello")

  local asst = render.durable_item_to_message({
    type = "message",
    role = "assistant",
    content = { { type = "output_text", text = "hi there" } },
  })
  h.eq(asst.role, "llm")
  h.eq(asst.content, "hi there")
end

T["skips resource events and tool outputs"] = function()
  h.eq(render.durable_item_to_message({ type = "resource_event" }), nil)
  h.eq(render.durable_item_to_message({ type = "function_call_output" }), nil)
end

T["renders function calls as a compact tool row"] = function()
  local m = render.durable_item_to_message({ type = "function_call", name = "read_file" })
  h.eq(m.role, "llm")
  h.is_true(m.content:find("read_file", 1, true) ~= nil)
  h.eq(m.opts.tool, true)
end

T["unknown durable items become a compact system row"] = function()
  local m = render.durable_item_to_message({ type = "mystery_item" })
  h.eq(m.content, "[Omnigent event: mystery_item]")
  h.eq(m.opts.system, true)
end

T["snapshot_messages maps a real /items page"] = function()
  local page = read_json("items-lifecycle.json")
  local msgs = render.snapshot_messages(page.data)
  -- 3 durable items: resource_event (skipped) + user + assistant.
  h.eq(#msgs, 2)
  h.eq(msgs[1].role, "user")
  h.eq(msgs[2].role, "llm")
  h.is_true(#msgs[1].content > 0)
  h.is_true(#msgs[2].content > 0)
end

return T
