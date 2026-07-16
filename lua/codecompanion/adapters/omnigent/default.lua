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
    -- RESERVED (Milestone 4): the session runtime does NOT yet reconnect a dropped
    -- SSE stream. Correct reconnect requires reconciling against GET /items (a naive
    -- reopen would double-render the in-flight text the stream replays on subscribe),
    -- so these are intentionally not honored until M4 lands.
    stream_reconnect = false,
    stream_heartbeat_timeout = 30000,
    history_page_size = 100, -- Page size for GET /items
    background_updates = false, -- M4: render externally-triggered background turns while idle
  },
  handlers = {
    -- Omnigent handles auth server-side (trusted proxy / local user); nothing to
    -- do client-side by default.
    auth = function()
      return true
    end,
  },
}
