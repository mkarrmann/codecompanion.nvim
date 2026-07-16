--=============================================================================
-- Default (generic) omnigent adapter.
--
-- This is the built-in template a user extends in their config, mirroring how
-- adapters/acp/claude_code.lua etc. work. All the omnigent protocol semantics
-- live in lua/codecompanion/omnigent/* (client/sse/events/session); this table
-- is pure configuration.
--=============================================================================

return {
  name = "omnigent",
  formatted_name = "Omnigent",
  type = "omnigent",
  -- Base URL of the omnigent-compatible server. May be a devserver tunnel URL.
  url = "http://127.0.0.1:6767",
  roles = {
    llm = "assistant",
    user = "user",
  },
  defaults = {
    -- Default agent name or id. NOTE: for the elicitation-gated posture (where
    -- CodeCompanion is the approval authority) configure a `claude-sdk`-harness
    -- agent (e.g. one like `polly`) rather than a `*-native-ui` agent, which runs
    -- host-side in a bypass/permission-less mode and never surfaces elicitations
    -- to the client. Override this in your own adapter config.
    agent = "claude-native-ui",
    -- Host binding: "auto" (fail-closed FQDN match), an explicit host id, or a
    -- host name. See omnigent/client.lua:resolve_host.
    host = "auto",
    -- Workspace on the resolved host: "auto" (cwd, only when the host is local)
    -- or an explicit absolute path.
    workspace = "auto",
    -- model_override = nil,
    -- reasoning_effort = nil,
    -- harness_override = nil,
  },
  opts = {
    -- M4 passive streaming. When `background_updates` is true the session keeps its
    -- SSE stream open at chat-attach and renders externally-triggered background
    -- turns (wakeups) through the observer while the chat is idle. That also enables
    -- auto-reconnect-on-drop with a GET /items reconcile (safe because the observer
    -- renders content-based and dedups the stream-first replay). `stream_reconnect`
    -- enables reconnect independently of background rendering. Reconnect is only ever
    -- attempted when the observer -- not a live foreground turn -- owns the stream.
    background_updates = false,
    stream_reconnect = false,
    stream_heartbeat_timeout = 30000, -- ms of stream silence before a forced reconnect (0 disables)
    reconnect_delay = 1000, -- ms before reopening a dropped stream
    history_page_size = 100, -- Page size for GET /items
  },
  handlers = {
    -- Omnigent handles auth server-side (trusted proxy / local user); nothing to
    -- do client-side by default.
    auth = function()
      return true
    end,
  },
}
