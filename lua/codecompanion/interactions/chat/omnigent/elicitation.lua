--=============================================================================
-- Omnigent elicitation handling (Milestone 5)
--
-- An omnigent agent (claude-sdk harness) can pause a turn to ask the client for
-- approval or structured input via `response.elicitation_request` (MCP-shaped:
-- { message, requestedSchema? }). CodeCompanion is the approval authority: it
-- surfaces the request in the chat buffer (reusing the shared approval prompt),
-- collects any structured input, and resolves it with an MCP action
-- (accept / decline / cancel) via POST .../elicitations/{id}/resolve. Until it is
-- resolved the server-side turn is blocked -- so this must never silently drop.
--=============================================================================

local labels = require("codecompanion.interactions.chat.tools.labels")
local log = require("codecompanion.utils.log")
local utils = require("codecompanion.utils")

local M = {}

---Human-readable message from MCP-shaped elicitation params.
---@param params any
---@return string
function M.message_of(params)
  if type(params) ~= "table" then
    return "Agent requested input"
  end
  return params.message or params.prompt or params.title or "Agent requested input"
end

---The requested-input schema (MCP) if this elicitation wants structured input.
---@param params any
---@return table|nil
function M.schema_of(params)
  if type(params) ~= "table" then
    return nil
  end
  local s = params.requestedSchema or params.requested_schema or params.schema
  if type(s) == "table" and type(s.properties) == "table" and next(s.properties) then
    return s
  end
  return nil
end

---Coerce a raw input string to the schema-declared type.
---@param spec table
---@param val string
---@return any
local function coerce(spec, val)
  local t = spec and spec.type
  if t == "number" or t == "integer" then
    return tonumber(val) or val
  elseif t == "boolean" then
    local v = tostring(val):lower()
    return v == "true" or v == "y" or v == "yes" or v == "1"
  end
  return val
end

---Prompt for each schema field in a stable order, then invoke cb(content).
---@param schema table
---@param cb fun(content: table)
function M.collect_fields(schema, cb)
  local props = schema.properties or {}
  local required = {}
  for _, r in ipairs(schema.required or {}) do
    required[r] = true
  end
  local order = {}
  for k in pairs(props) do
    order[#order + 1] = k
  end
  table.sort(order)

  local content = {}
  local i = 0
  local function next_field()
    i = i + 1
    local key = order[i]
    if not key then
      return cb(content)
    end
    local spec = props[key] or {}
    local title = spec.title or key
    local req = required[key] and " *" or ""
    local desc = spec.description and (" — " .. spec.description) or ""
    vim.ui.input({ prompt = title .. req .. desc .. ": " }, function(val)
      if val ~= nil and val ~= "" then
        content[key] = coerce(spec, val)
      end
      next_field()
    end)
  end
  next_field()
end

---Present one elicitation and resolve it. Idempotent per request.
---@param chat CodeCompanion.Chat
---@param session CodeCompanion.Omnigent.Session
---@param elicitation table { elicitation_id, method?, params? }
function M.handle(chat, session, elicitation)
  local eid = elicitation.elicitation_id
  if not eid then
    log:error("[Omnigent::Elicitation] request without an id; cannot resolve")
    return
  end
  local params = elicitation.params
  local schema = M.schema_of(params)
  local keys = labels.keymaps()
  local approval_prompt = require("codecompanion.interactions.chat.helpers.approval_prompt")

  local resolved = false
  local function resolve(action, content)
    if resolved then
      return
    end
    resolved = true
    local result = { action = action }
    if content and next(content) then
      result.content = content
    end
    local ok, err = session:resolve_elicitation(eid, result)
    if not ok then
      log:error("[Omnigent::Elicitation] resolve failed: %s", (type(err) == "table" and err.message) or tostring(err))
      utils.notify("Omnigent: failed to resolve elicitation", vim.log.levels.ERROR)
    end
    if session.pending_elicitations then
      session.pending_elicitations[eid] = nil
    end
  end

  local choices = {
    {
      keymap = keys.accept,
      label = schema and (labels.accept .. " (provide input)") or labels.accept,
      callback = function()
        if schema then
          M.collect_fields(schema, function(content)
            resolve("accept", content)
          end)
        else
          resolve("accept")
        end
      end,
    },
    {
      keymap = keys.reject,
      label = "Decline",
      callback = function()
        resolve("decline")
      end,
    },
    {
      keymap = keys.cancel,
      label = labels.cancel,
      callback = function()
        resolve("cancel")
      end,
    },
  }

  local prompt = M.message_of(params)
  if elicitation.method then
    prompt = prompt .. "\n_(" .. tostring(elicitation.method) .. ")_"
  end

  approval_prompt.request(chat, {
    id = eid,
    title = "Omnigent approval",
    prompt = prompt,
    choices = choices,
  })
end

return M
