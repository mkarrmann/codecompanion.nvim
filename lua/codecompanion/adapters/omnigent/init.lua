local config = require("codecompanion.config")
local log = require("codecompanion.utils.log")
local shared = require("codecompanion.adapters.shared")

---@class CodeCompanion.OmnigentAdapter
---@field name string The name of the adapter
---@field formatted_name string The formatted name of the adapter
---@field type string|"omnigent" The type of the adapter
---@field url string Base URL of the omnigent-compatible server
---@field roles table The mapping of roles in the config to the LLM's defined roles
---@field defaults? table { agent, host, workspace, model_override?, reasoning_effort?, harness_override?, labels? }
---@field opts? table Additional options (stream_reconnect, history_page_size, background_updates, ...)
---@field env? table Environment variables referenced in the parameters
---@field handlers? table { auth?, setup?, teardown? }

---@class CodeCompanion.OmnigentAdapter
local Adapter = {}

---@return CodeCompanion.OmnigentAdapter
function Adapter.new(args)
  return setmetatable(args, { __index = Adapter })
end

Adapter.map_roles = shared.map_roles

---Extend an existing adapter
---@param adapter table|string|function
---@param opts? table
---@return CodeCompanion.OmnigentAdapter
function Adapter.extend(adapter, opts)
  local ok
  local adapter_config
  opts = opts or {}

  if type(adapter) == "string" then
    ok, adapter_config = pcall(require, "codecompanion.adapters.omnigent." .. adapter)
    if not ok then
      adapter_config = (config.adapters.omnigent and config.adapters.omnigent[adapter]) or config.adapters[adapter]
      if type(adapter_config) == "function" then
        adapter_config = adapter_config()
      end
    end
  elseif type(adapter) == "function" then
    adapter_config = adapter()
  else
    adapter_config = adapter
  end

  if not adapter_config then
    return log:error("[adapters::omnigent::extend] Adapter not found: %s", adapter)
  end

  adapter_config = vim.tbl_deep_extend("force", {}, vim.deepcopy(adapter_config), opts or {})
  if not adapter_config.type then
    adapter_config.type = "omnigent"
  end

  return Adapter.new(adapter_config)
end

---Resolve an adapter from a name, table or function.
---@param adapter? CodeCompanion.OmnigentAdapter|string|function
---@param opts? table
---@return CodeCompanion.OmnigentAdapter
function Adapter.resolve(adapter, opts)
  adapter = adapter or config.interactions.chat.adapter
  opts = opts or {}

  local key = type(adapter) == "string" and adapter or nil

  if type(adapter) == "table" then
    -- Handle { name = "omnigent", model = "..." } style config first.
    if adapter.name and adapter.model and not adapter.type then
      return Adapter.resolve(adapter.name, { model = adapter.model })
    elseif adapter.name and not adapter.type then
      return Adapter.resolve(adapter.name)
    end

    if opts.model then
      adapter = vim.tbl_deep_extend("force", vim.deepcopy(adapter), {
        defaults = { model_override = opts.model },
      })
    end

    adapter = Adapter.new(adapter)
  elseif type(adapter) == "string" then
    local mapped = config.adapters.omnigent and config.adapters.omnigent[adapter]
    if not mapped then
      -- Allow resolving a built-in provider by file name directly.
      local ok = pcall(require, "codecompanion.adapters.omnigent." .. adapter)
      if not ok then
        return log:error("[adapters::omnigent::resolve] Adapter not found: %s", adapter)
      end
    end
    adapter = Adapter.extend(mapped or adapter)
    if opts.model then
      adapter.defaults = adapter.defaults or {}
      adapter.defaults.model_override = opts.model
    end
  elseif type(adapter) == "function" then
    adapter = adapter()
  end

  if not adapter.type then
    adapter.type = "omnigent"
  end

  shared.apply_extend(adapter, { extend = config.adapters.omnigent and config.adapters.omnigent.extend, key = key })

  return adapter
end

---Check if an adapter has already been resolved
---@param adapter CodeCompanion.OmnigentAdapter|string|function|nil
---@return boolean
function Adapter.resolved(adapter)
  if adapter and getmetatable(adapter) and getmetatable(adapter).__index == Adapter then
    return true
  end
  return false
end

---Make an adapter safe for serialization
---@param adapter CodeCompanion.OmnigentAdapter
---@return table
function Adapter.make_safe(adapter)
  return {
    name = adapter.name,
    formatted_name = adapter.formatted_name,
    type = adapter.type,
    url = adapter.url,
    defaults = adapter.defaults,
    opts = adapter.opts,
    handlers = adapter.handlers,
  }
end

---Set the model for an omnigent adapter. If a live session runtime is supplied it
---is asked to patch the running session (PATCH model_override); otherwise the
---choice is stashed on the adapter defaults for the next session creation.
---@param args { adapter?: CodeCompanion.OmnigentAdapter, omnigent_session?: table, model: string }
---@return boolean
function Adapter.set_model(args)
  if args.omnigent_session and args.omnigent_session.set_model then
    return args.omnigent_session:set_model(args.model)
  end
  if args.adapter then
    args.adapter.defaults = args.adapter.defaults or {}
    args.adapter.defaults.model_override = args.model
  end
  return true
end

return Adapter
