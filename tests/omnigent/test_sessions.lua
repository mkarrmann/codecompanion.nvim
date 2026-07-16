local h = require("tests.helpers")
local new_set = MiniTest.new_set

local S = require("codecompanion.interactions.chat.omnigent.sessions")

local T = new_set()

local function read_json(name)
  return vim.json.decode(table.concat(vim.fn.readfile("tests/stubs/omnigent/" .. name), "\n"))
end

T["relative formats ages"] = function()
  local now = 1000000
  h.eq(S.relative(now - 5, now), "5s")
  h.eq(S.relative(now - 120, now), "2m")
  h.eq(S.relative(now - 7200, now), "2h")
  h.eq(S.relative(now - 172800, now), "2d")
  h.eq(S.relative(nil, now), "?")
  -- Future timestamps clamp to 0s (clock skew).
  h.eq(S.relative(now + 100, now), "0s")
end

T["short_workspace trims deep paths"] = function()
  h.eq(S.short_workspace("/home/me/checkout1/fbsource"), ".../checkout1/fbsource")
  h.eq(S.short_workspace("/a/b"), "/a/b")
  h.eq(S.short_workspace(""), "")
  h.eq(S.short_workspace(nil), "")
end

T["format_summary includes title, agent, status, age, workspace"] = function()
  local now = 2000000
  local label = S.format_summary({
    id = "conv_1",
    title = "fix the bug",
    agent_name = "polly",
    status = "completed",
    updated_at = now - 60,
    workspace = "/home/me/checkout1/fbsource",
    pending_elicitations_count = 0,
  }, { now = now })
  h.is_true(label:find("fix the bug", 1, true) ~= nil)
  h.is_true(label:find("polly", 1, true) ~= nil)
  h.is_true(label:find("completed", 1, true) ~= nil)
  h.is_true(label:find("1m", 1, true) ~= nil)
  h.is_true(label:find("fbsource", 1, true) ~= nil)
end

T["format_summary falls back to id when no title, flags pending"] = function()
  local label = S.format_summary({ id = "conv_x", pending_elicitations_count = 2 }, { now = 0 })
  h.is_true(label:find("conv_x", 1, true) ~= nil)
  h.is_true(label:find("2", 1, true) ~= nil)
end

T["active drops archived sessions"] = function()
  local out = S.active({
    { id = "a", archived = false },
    { id = "b", archived = true },
    { id = "c" },
  })
  h.eq(#out, 2)
  h.eq(out[1].id, "a")
  h.eq(out[2].id, "c")
end

T["filter_by_workspace exact match"] = function()
  local out = S.filter_by_workspace({
    { id = "a", workspace = "/x" },
    { id = "b", workspace = "/y" },
    { id = "c", workspace = "/x" },
  }, "/x")
  h.eq(#out, 2)
end

T["filter_by_label matches label key/value"] = function()
  local out = S.filter_by_label({
    { id = "a", labels = { ["orchest.tab"] = "work" } },
    { id = "b", labels = { ["orchest.tab"] = "play" } },
    { id = "c" },
  }, "orchest.tab", "work")
  h.eq(#out, 1)
  h.eq(out[1].id, "a")
end

T["by_recency sorts newest first, non-destructive"] = function()
  local input = {
    { id = "old", updated_at = 100 },
    { id = "new", updated_at = 300 },
    { id = "mid", updated_at = 200 },
  }
  local out = S.by_recency(input)
  h.eq(out[1].id, "new")
  h.eq(out[2].id, "mid")
  h.eq(out[3].id, "old")
  -- original order preserved
  h.eq(input[1].id, "old")
end

T["works on the real readonly-sessions fixture"] = function()
  local body = read_json("readonly-sessions.json")
  local data = body.data or body.sessions or body
  local ranked = S.by_recency(S.active(data))
  h.is_true(#ranked >= 1)
  local label = S.format_summary(ranked[1], { now = os.time() })
  h.is_true(type(label) == "string" and #label > 0)
end

return T
