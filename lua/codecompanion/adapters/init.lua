local config = require("codecompanion.config")

local M = {}

---Determine the adapter type
---@param adapter string|table|nil
---@return string
local function adapter_type(adapter)
  -- If no adapter provided, use the default from config
  if adapter == nil then
    adapter = config.interactions.chat.adapter
  end

  if type(adapter) == "table" and adapter.type then
    return adapter.type
  end

  -- Check by name (for tables like { name = "claude_code", model = "opus" })
  local name = type(adapter) == "string" and adapter or (type(adapter) == "table" and adapter.name)
  if name then
    if config.adapters.omnigent and config.adapters.omnigent[name] then
      return "omnigent"
    end
    if config.adapters.acp and config.adapters.acp[name] then
      return "acp"
    end
    if config.adapters.http and config.adapters.http[name] then
      return "http"
    end
  end

  -- The fallback
  return "http"
end

---Factory method to resolve adapters
---@param adapter string|table
---@param opts? table
---@return CodeCompanion.ACPAdapter|CodeCompanion.HTTPAdapter
function M.resolve(adapter, opts)
  local t = adapter_type(adapter)
  if t == "omnigent" then
    return require("codecompanion.adapters.omnigent").resolve(adapter, opts)
  end
  if t == "acp" then
    return require("codecompanion.adapters.acp").resolve(adapter, opts)
  end
  return require("codecompanion.adapters.http").resolve(adapter, opts)
end

---Factory method to check if the adapter has been resolved
---@param adapter string|table
---@return boolean
function M.resolved(adapter)
  if not adapter then
    return false
  end

  local t = adapter_type(adapter)
  if t == "omnigent" then
    return require("codecompanion.adapters.omnigent").resolved(adapter)
  end
  if t == "acp" then
    return require("codecompanion.adapters.acp").resolved(adapter)
  end
  return require("codecompanion.adapters.http").resolved(adapter)
end

---Factory method to extend the adapter
---@param adapter string|table
---@param opts? table
---@return CodeCompanion.ACPAdapter|CodeCompanion.HTTPAdapter
function M.extend(adapter, opts)
  local t = adapter_type(adapter)
  if t == "omnigent" then
    return require("codecompanion.adapters.omnigent").extend(adapter, opts)
  end
  if t == "acp" then
    return require("codecompanion.adapters.acp").extend(adapter, opts)
  end
  return require("codecompanion.adapters.http").extend(adapter, opts)
end

---Factory method to make adapters safe for serialization
---@param adapter string|table
---@return table
function M.make_safe(adapter)
  local t = adapter_type(adapter)
  if t == "omnigent" then
    return require("codecompanion.adapters.omnigent").make_safe(adapter)
  end
  if t == "acp" then
    return require("codecompanion.adapters.acp").make_safe(adapter)
  end
  return require("codecompanion.adapters.http").make_safe(adapter)
end

---Backwards compatibility: expose HTTP methods directly at root level
---@param args { adapter: CodeCompanion.HTTPAdapter|CodeCompanion.ACPAdapter, acp_connection?: CodeCompanion.ACP.Connection, model?: string }
---@return CodeCompanion.HTTPAdapter
function M.set_model(args)
  local t = adapter_type(args.adapter)
  if t == "omnigent" then
    return require("codecompanion.adapters.omnigent").set_model(args)
  end
  if t == "acp" then
    return require("codecompanion.adapters.acp").set_model(args)
  end
  return require("codecompanion.adapters.http").set_model(args)
end

---Get a handler function from an adapter with backwards compatibility
---@param adapter CodeCompanion.HTTPAdapter
---@param handler_name string
---@return nil
function M.get_handler(adapter, handler_name)
  return require("codecompanion.adapters.http").get_handler(adapter, handler_name)
end

---Call a handler on an adapter with backwards compatibility
---@param adapter CodeCompanion.HTTPAdapter
---@param handler_name string
---@param ... any Additional arguments to pass to the handler
---@return any|nil
function M.call_handler(adapter, handler_name, ...)
  local handler = M.get_handler(adapter, handler_name)
  if handler then
    return handler(adapter, ...)
  end
  return nil
end

return M
