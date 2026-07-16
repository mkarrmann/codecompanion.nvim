# Native Omnigent Integration Design

> **⚠️ STATUS (read first): this is the ORIGINAL design and is partly WRONG.**
> It predates implementation. Several core assumptions were corrected by
> empirically-captured fixtures — notably: ids are opaque (not `conv_`/`ag_`);
> assistant-text dedup is content-based (deltas carry no ids); reconnect is
> stream-first (in-flight text is replayed on subscribe, not in `/items`); host
> binding is `external`/`managed` with fail-closed resolution; the model catalog
> comes from the `session.model_options` event, not a REST endpoint. **Before
> implementing anything, read `omnigent-native-progress.md` (state + how to run +
> invariants) and `omnigent-native-roadmap.md` (task breakdown), and trust the
> fixtures in `.codecompanion/omnigent-fixtures/` over this document.**

## Position

CodeCompanion should support Omnigent as a first-class sessionful agent
protocol, not through an ACP facade and not by squeezing it into the existing
HTTP adapter model.

Omnigent is not just another chat-completions endpoint. It is a meta-harness:

- sessions are durable server-side objects;
- sessions can run on remote hosts/devservers;
- sessions can be resumed by multiple clients;
- sessions can wake without CodeCompanion initiating the turn;
- sessions expose status, model, effort, tools, permissions, sub-agents,
  background work, timers, and durable transcript history;
- sessions may be driven by different underlying harnesses while preserving one
  shared Omnigent protocol.

The proper CodeCompanion integration is therefore a new generic protocol family:

```text
CodeCompanion chat
  <-> CodeCompanion Omnigent client/runtime
  <-> Omnigent-compatible REST + SSE server
  <-> Omnigent runner / host / harness implementation
```

The server implementation may be the current Omnigent server or a future
compatible implementation. CodeCompanion should depend on the protocol contract,
not on local files, SQLite, or a specific Python package layout.

## Target Repository

Implement CodeCompanion-side changes in this checkout:

```text
/Users/mkarrmann/repos/codecompanion.nvim
```

All paths in this document are relative to that repository unless explicitly
qualified otherwise. Omnigent server/API changes, if required, belong in:

```text
/Users/mkarrmann/repos/omnigent
```

Dotfiles should only contain local user configuration that selects and configures
the Omnigent adapter; protocol/runtime support belongs in the CodeCompanion
repo.

## Non-Goals

- Do not build an ACP stdio facade.
- Do not pretend Omnigent is a stateless HTTP LLM adapter.
- Do not access Omnigent SQLite or local stores.
- Do not leave a fake long-running CodeCompanion prompt open to capture
  background wakeups.
- Do not require per-agent scripts that call Omnigent APIs directly.
- Do not make Omnigent sessions Mac-local when CodeCompanion is running on a
  devserver.
- Do not auto-approve permissions/elicitations.

## Terminology

- **Omnigent-compatible server**: A server implementing the session, event,
  stream, host, agent, and metadata APIs described below.
- **Session**: A durable Omnigent conversation id, normally `conv_*`.
- **Host**: A machine registered with the Omnigent server. This may be the Mac
  or a devserver.
- **Workspace**: The absolute working directory on the selected host.
- **Foreground turn**: A turn initiated by the current CodeCompanion chat
  submit action.
- **Background turn**: A turn initiated by another client or external event
  while CodeCompanion is attached but not actively submitting.
- **Wakeup**: A background event that posts a user/meta message into a session
  and causes Omnigent to run a turn.
- **Durable item**: A transcript item returned by the Omnigent history/items
  API.
- **Live event**: An SSE event returned by the Omnigent stream API.

## Protocol Contract

The CodeCompanion client should target a generic Omnigent protocol with these
capabilities.

Required endpoints:

- `GET /v1/agents`
- `GET /v1/hosts`
- `POST /v1/sessions`
- `GET /v1/sessions`
- `GET /v1/sessions/{session_id}`
- `PATCH /v1/sessions/{session_id}`
- `GET /v1/sessions/{session_id}/items`
- `GET /v1/sessions/{session_id}/stream`
- `POST /v1/sessions/{session_id}/events`

Optional endpoints:

- Elicitation-specific resolve endpoint.
- Agent/session capability discovery endpoint.
- Model catalog endpoint.
- Runner/host liveness endpoint beyond data embedded in session snapshots.

The protocol must be treated as REST + live event stream:

- `GET /items` is the durable source of transcript truth.
- `GET /stream` is live-tail and may not replay complete history.
- CodeCompanion must reconcile snapshots and streams by stable ids where
  available.
- CodeCompanion must survive SSE reconnects by refetching snapshots/items and
  deduping.

## Adapter Type

Add a third adapter family:

```lua
adapter.type == "omnigent"
```

This is distinct from:

- `http`: stateless request/response LLM calls where CodeCompanion owns the
  transcript and tool execution.
- `acp`: stdio JSON-RPC session protocol where an external process owns the
  agent session.
- `omnigent`: REST + SSE session protocol where an Omnigent-compatible server
  owns sessions, history, execution, tools, wakeups, and host binding.

Top-level factory changes:

- `lua/codecompanion/adapters/init.lua` should resolve `omnigent`.
- `config.adapters.omnigent` should mirror `http` / `acp` organization.
- `adapters.make_safe`, `adapters.set_model`, and model listing should support
  `omnigent`.
- UI metadata should report `adapter.type = "omnigent"`.

Suggested file layout:

```text
lua/codecompanion/adapters/omnigent/init.lua
lua/codecompanion/adapters/omnigent/default.lua
lua/codecompanion/omnigent/client.lua
lua/codecompanion/omnigent/sse.lua
lua/codecompanion/omnigent/session.lua
lua/codecompanion/omnigent/events.lua
lua/codecompanion/interactions/chat/omnigent/handler.lua
lua/codecompanion/interactions/chat/omnigent/render.lua
lua/codecompanion/interactions/chat/omnigent/request_permission.lua
tests/adapters/omnigent/
tests/omnigent/
tests/interactions/chat/omnigent/
```

## Configuration

Minimal adapter config:

```lua
adapters = {
  omnigent = {
    default = {
      name = "omnigent",
      formatted_name = "Omnigent",
      type = "omnigent",
      url = "http://127.0.0.1:6767",
      defaults = {
        agent = "claude-native-ui",
        host = "auto",
        workspace = "auto",
      },
    },
  },
}
```

Required settings:

- `url`: Omnigent server base URL. May be a devserver tunnel URL.
- `agent`: default agent name or id.
- `host`: `auto`, explicit host id, or host name.
- `workspace`: `auto` or explicit workspace path.

Optional settings:

- `model_override`
- `reasoning_effort`
- `harness_override`
- `labels`
- `stream_reconnect`
- `stream_heartbeat_timeout`
- `history_page_size`
- `resume_filter`
- `background_updates`

The default should favor current editor context:

- `workspace = vim.fn.getcwd()`
- host auto-resolved from current machine identity
- labels include CodeCompanion client metadata

## Core Runtime Objects

### Omnigent Client

`codecompanion.omnigent.client` owns HTTP calls:

- request construction;
- JSON encoding/decoding;
- error normalization;
- auth headers if configured;
- environment substitution;
- testable method injection.

It should expose methods like:

```lua
client:list_agents()
client:list_hosts()
client:create_session(body)
client:list_sessions(params)
client:get_session(session_id, opts)
client:update_session(session_id, body)
client:list_items(session_id, params)
client:post_event(session_id, body)
client:stream_session(session_id, opts)
```

### SSE Stream

`codecompanion.omnigent.sse` owns:

- connecting to `GET /stream`;
- parsing SSE frames;
- handling `[DONE]`;
- reconnecting;
- heartbeats/timeouts;
- propagating events to a session reducer.

It must not directly mutate chat buffers. It emits parsed protocol events to a
session runtime object.

### Session Runtime

`codecompanion.omnigent.session` owns:

- session id;
- agent id/name;
- host/workspace;
- current status;
- current model/effort;
- durable item cursor;
- rendered item ids;
- active foreground request, if any;
- active background turn, if any;
- stream connection state;
- pending elicitations;
- reconnect/snapshot reconciliation.

This object is the conceptual equivalent of `acp.Connection`, but for Omnigent.

## Chat Integration

Add a submit path:

```lua
Chat:_submit_omnigent(payload)
```

and route:

```lua
if self.adapter.type == "omnigent" then
  self:_submit_omnigent(payload)
end
```

The Omnigent chat handler should be analogous to ACP's chat handler but not
derived from ACP:

- ensure client;
- ensure or create Omnigent session;
- ensure stream;
- post the foreground prompt;
- render stream events;
- complete the CodeCompanion request when the Omnigent turn ends.

The handler must send only new user messages. It should mirror ACP's unsent
message behavior rather than HTTP's full transcript behavior. Omnigent already
has durable history.

## Session Creation

On first submit or explicit new-session action:

1. Resolve adapter config.
2. Resolve agent:
   - if configured value looks like `ag_*`, use it;
   - otherwise fetch `GET /v1/agents` and match by name.
3. Resolve host:
   - if explicit host id is configured, use it;
   - if `auto`, fetch `GET /v1/hosts`;
   - match current machine by hostname/FQDN where possible;
   - if multiple candidates match, prefer online host;
   - fail loudly if a host-bound harness needs a host and none is resolved.
4. Resolve workspace:
   - `auto` uses current Neovim cwd;
   - path must be absolute on the resolved host.
5. Create session via `POST /v1/sessions`.
6. Store `session_id = conv_*` on the chat/session runtime.
7. Start stream subscription.

CodeCompanion's own `chat.session_id` can remain an internal chat id, but the
Omnigent session id must be tracked separately and exposed in metadata. Avoid
overloading unrelated ids.

## Foreground Turn Flow

For a user submit:

1. Parse user input into CodeCompanion messages as today.
2. Add user message to `chat.messages`.
3. Ensure Omnigent session.
4. Build only unsent user content into Omnigent input blocks.
5. Connect or verify stream subscription before posting where practical.
6. `POST /v1/sessions/{id}/events` with `type = "message"`.
7. Set `chat.current_request` to a handle with:
   - `cancel()`;
   - `status()`;
   - session id;
   - foreground request state.
8. Render live events.
9. On terminal event, persist the assistant message into `chat.messages`.
10. Mark user messages sent.
11. `chat:ready_for_input()`.

Cancel should post:

```json
{"type": "interrupt", "data": {}}
```

It should not delete or stop the session.

## Background Turn Flow and Wakeups

This is the main reason native support is required.

An Omnigent session can receive a message from an external watcher, another UI,
another client, a timer, or an agent orchestration path while CodeCompanion is
attached but idle.

CodeCompanion must treat this as a background turn, not as a fake user submit.

When attached to an Omnigent session and background updates are enabled:

1. Keep an SSE stream open while the chat buffer exists.
2. Receive live events regardless of whether `chat.current_request` is set.
3. Distinguish foreground vs background by local active request state and event
   ids/status.
4. For background user/meta input:
   - append a user or system/meta message to the buffer;
   - mark it as externally originated;
   - do not trigger local submit.
5. For background assistant output:
   - append/stream an assistant block;
   - update status;
   - persist to `chat.messages` when durable item or terminal event arrives.
6. On reconnect:
   - fetch session snapshot and `/items`;
   - render missing durable turns;
   - dedupe against rendered item ids and in-flight event ids.

The UI should make background turns visually distinguishable enough to avoid
confusing them with local user submissions. For example:

```text
User (external)
System wakeup: CI run failed for D123...

Assistant
I inspected the failed job...
```

Background wakeups should trigger `ChatOmnigentWakeup` / `ChatOmnigentBackgroundTurn`
events so users can configure notifications.

## Stream and History Reconciliation

The stream is live; history is durable. The integration must reconcile both.

Rules:

- Never assume stream events are complete after reconnect.
- Never assume `GET /items` includes in-flight deltas.
- Prefer stable item ids when deciding whether content is already rendered.
- Keep a set of rendered durable item ids.
- Keep a temporary live-response accumulator for events without item ids.
- When a final durable item arrives, replace or mark the live accumulator as
  committed instead of duplicating text.
- If durable history disagrees with live text, durable history wins after turn
  completion.

The renderer should support two paths:

- **snapshot render**: rebuild buffer from `/items`;
- **incremental render**: apply live events to the existing buffer.

The resume command can use snapshot render. The live stream should use
incremental render plus periodic/safety reconciliation.

## Event Mapping

At minimum, support these live events:

- `session.status`
- `session.input.consumed`
- `session.usage`
- `session.model`
- `session.reasoning_effort`
- `response.output_text.delta`
- `response.reasoning.started`
- `response.reasoning_text.delta`
- `response.reasoning_summary_text.delta`
- `response.output_item.done`
- `response.completed`
- `response.failed`
- `response.cancelled`
- `response.incomplete`
- `response.error`
- `response.elicitation_request`
- `response.elicitation_resolved`
- `session.interrupted`
- `session.created`
- child/sub-agent update events if exposed by the protocol

The reducer should normalize events into CodeCompanion-domain updates:

```lua
{
  kind = "message_delta" | "reasoning_delta" | "tool_call" |
         "tool_result" | "status" | "usage" | "elicitation" |
         "turn_started" | "turn_completed" | "turn_failed" |
         "session_changed" | "child_session",
  session_id = "...",
  item_id = "...",
  response_id = "...",
  data = ...
}
```

Do not scatter raw Omnigent event handling through chat UI code. Normalize once.

## Durable Item Mapping

History renderer must support common durable items:

- user messages;
- assistant messages;
- reasoning summaries when stored;
- function/tool calls;
- tool results;
- native tool calls;
- slash commands;
- terminal/native status markers;
- policy denials;
- elicitation requests/resolutions;
- child session creation/completion summaries.

Initial implementation may render unknown item types as compact system rows, but
it must not discard them in a way that corrupts the user's understanding of the
session. For unknown items:

```text
[Omnigent event: <type>]
```

with details optionally folded.

## Meta-Harness Support

The integration must expose Omnigent's meta-harness semantics, not just text
chat.

### Sessions and Sub-Agents

Omnigent sessions can spawn child sessions. CodeCompanion should surface:

- child session creation;
- child status;
- child title/agent;
- child completion/failure;
- links or commands to open/resume child sessions.

It does not need to recreate Omnigent's full session tree UI initially, but it
should preserve and display enough information that a user knows agents are
working elsewhere.

Potential UI:

- a small status line in the chat;
- foldable child session event rows;
- slash command to list/open child sessions;
- metadata events for external integrations.

### Async Work and Inbox

Omnigent agents may use `sys_call_async`, `sys_read_inbox`, and sub-agent inbox
delivery. CodeCompanion should treat these as server-side tool/meta events:

- show task started/running/completed/cancelled when events exist;
- render inbox completions as assistant/system-visible content if they are
  durable items;
- do not attempt to implement the inbox locally.

### Timers

Timers may wake sessions by injecting meta messages. CodeCompanion should render
timer wakeups as background/meta user messages. It should not assume timers are
durable across server restarts unless the server exposes that guarantee.

### Tools

Omnigent owns server-side tools. CodeCompanion should not automatically send its
local chat tool registry to Omnigent as if this were an HTTP model.

Future client-side tool bridging can be added explicitly:

- server emits a client-tool request;
- CodeCompanion runs an approved local tool;
- CodeCompanion posts the result back through Omnigent.

That is separate from initial native support and must have explicit permission
and security design.

### Elicitations and Permissions

Omnigent elicitations are first-class. CodeCompanion must:

- display pending elicitations;
- support accept/decline/cancel where shape is simple;
- support forms if Omnigent sends structured form schemas and CodeCompanion can
  render them;
- support "open in Omnigent" fallback for complex or URL-backed elicitations;
- post resolution back to the server;
- never auto-approve.

This should reuse as much of ACP's permission UI as practical, but the internal
model should not be ACP-specific.

### Model, Effort, and Config

CodeCompanion's model picker should support Omnigent:

- list models from server/session capability when available;
- patch `model_override`;
- patch `reasoning_effort`;
- update chat metadata when stream emits model/effort changes.

Native harnesses may change model/effort from another UI or terminal. Those
changes should flow back into CodeCompanion via stream events.

## Commands and UI

Add or generalize commands:

- `/resume`: support Omnigent sessions, not only ACP.
- `/session`: show current session id, agent, host, workspace, status.
- `/sessions`: list accessible Omnigent sessions and open/resume.
- `/children`: list child sessions for the current session.
- `/open_omnigent`: open the current session in Omnigent UI, if URL is known.
- `/model`: use Omnigent model patching.
- `/effort`: use Omnigent reasoning effort patching.

Existing ACP-specific commands should either remain ACP-only or be generalized
behind a sessionful adapter interface.

Chat metadata should include:

```lua
omnigent = {
  session_id = "conv_...",
  agent_id = "ag_...",
  agent_name = "...",
  host_id = "...",
  host_name = "...",
  workspace = "...",
  status = "idle|running|waiting|failed|...",
  model = "...",
  reasoning_effort = "...",
  pending_elicitations = 0,
}
```

## Generic Sessionful Adapter Interface

Avoid hardcoding every future behavior into `if adapter.type == "omnigent"`.
Introduce a generic sessionful adapter interface and implement Omnigent behind
it.

Suggested methods:

```lua
adapter.session = {
  ensure = function(chat, payload) end,
  submit = function(chat, payload) end,
  cancel = function(chat) end,
  list = function(chat, opts) end,
  load = function(chat, session_id, opts) end,
  set_model = function(chat, model) end,
  set_config = function(chat, key, value) end,
  close = function(chat) end,
}
```

Then `acp` can eventually be adapted to this interface too. That reduces
branching and makes `resume`, model selection, metadata, and cancellation
transport-neutral.

Pragmatic path:

1. Add `omnigent` branches directly where needed to get the first version
   working.
2. Immediately factor shared semantics into `codecompanion.interactions.chat.session`.
3. Migrate ACP resume/model/session metadata onto the shared interface.

## State Machine

A chat attached to an Omnigent session has two related state machines.

### Connection State

```text
disconnected
  -> resolving_config
  -> resolving_agent
  -> resolving_host
  -> creating_or_loading_session
  -> streaming
  -> reconnecting
  -> streaming
  -> closed
```

Failures should surface with actionable messages.

### Turn State

```text
idle
  -> foreground_submitting
  -> foreground_streaming
  -> idle

idle
  -> background_started
  -> background_streaming
  -> idle

foreground_streaming
  -> cancelling
  -> idle

background_streaming
  -> waiting_for_elicitation
  -> background_streaming
  -> idle
```

Foreground and background should not both mutate the same render accumulator
without a response id/item id. If a background turn starts while a local turn is
active, CodeCompanion should fail loud or display a clear conflict unless the
server explicitly supports concurrent turns with separate response ids.

## Error Handling

Normalize server errors:

- connection refused;
- auth failed;
- agent not found;
- host not found/offline;
- workspace invalid;
- session not found;
- access denied;
- runner offline;
- event rejected;
- stream disconnected;
- protocol violation;
- elicitation resolution failed.

Every error should include:

- user-facing message;
- server status/code when available;
- retryability;
- suggested action.

## Security Model

Omnigent owns server-side execution and policies. CodeCompanion must not bypass
that.

Rules:

- Do not run local tools for Omnigent unless the protocol explicitly asks for a
  client-side tool and the user approves.
- Do not auto-resolve elicitations.
- Do not expose arbitrary session sharing controls unless the server grants and
  the user explicitly asks.
- Do not leak local Mac paths into devserver sessions.
- Do not silently downgrade from remote host execution to local execution.
- Respect server access errors as authoritative.

## Testing

Unit tests:

- adapter resolution for `omnigent`;
- Omnigent client request construction;
- SSE parser;
- event normalization;
- durable item renderer;
- host resolution;
- session create/load/list;
- model/effort patch;
- foreground turn lifecycle;
- background turn lifecycle;
- reconnect + dedupe;
- elicitation mapping;
- cancel/interrupt.

Fixtures:

- session list response;
- host list response;
- session snapshot;
- items page with user/assistant/tool/native events;
- SSE text deltas;
- SSE reasoning deltas;
- SSE tool events;
- SSE elicitation request/resolution;
- SSE background wakeup sequence;
- SSE reconnect sequence with duplicated events.

Integration tests with fake server:

- create session and submit prompt;
- stream response to chat buffer;
- resume session from items;
- background wakeup appends while idle;
- cancel active turn;
- reconnect stream and avoid duplicate output.

Manual tests:

- Mac-local Omnigent server.
- Devserver CodeCompanion via tunnel to Mac server.
- Create session from CodeCompanion and verify host/workspace in Omnigent.
- Resume same session from Omnigent UI.
- External watcher posts a message; CodeCompanion renders background turn.
- Pending elicitation appears and can be resolved.
- Model/effort changed in Omnigent UI updates CodeCompanion metadata.

## Implementation Plan

### Milestone 1: Protocol Client and Adapter Type

- Add `omnigent` adapter family.
- Add generic Omnigent client.
- Add SSE parser.
- Add tests for client/SSE/event normalization.

No chat UI behavior yet.

### Milestone 2: Foreground Chat

- Add `_submit_omnigent`.
- Create/load session.
- Post foreground message.
- Stream assistant text/reasoning.
- Complete request and persist messages.
- Cancel via interrupt.

This makes Omnigent usable for normal CodeCompanion chat.

### Milestone 3: Resume/List/Metadata

- Generalize `/resume` or add Omnigent resume.
- Render durable `/items`.
- List sessions.
- Expose metadata: session id, host, workspace, status, model, effort.
- Model/effort patching.

This makes CodeCompanion a real Omnigent session client.

### Milestone 4: Wakeups and Passive Streaming

- Keep stream open while attached.
- Render background turns while idle.
- Reconcile on reconnect.
- Dedupe against durable items.
- Fire wakeup/background-turn autocmds.

This is the milestone that ACP cannot provide cleanly today.

### Milestone 5: Meta-Harness Richness

- Elicitations.
- Tool/native event rendering.
- Child sessions/sub-agent status.
- Inbox/task/timer meta events.
- Open child/current session in Omnigent UI.

This makes CodeCompanion reflect Omnigent's full meta-harness model.

### Milestone 6: Refactor Sessionful Adapter Interface

- Extract transport-neutral sessionful operations.
- Move ACP and Omnigent resume/model/session metadata toward shared APIs.
- Reduce `adapter.type` branching.

This is important before adding another sessionful protocol in the future.

## Open Questions

- What is the stable discovery endpoint for Omnigent protocol capabilities?
- Which live event fields are guaranteed stable ids for dedupe?
- Should CodeCompanion keep a stream open for hidden chat buffers, visible chat
  buffers only, or all attached sessions?
- How should background turns be rendered if they arrive while the user is
  editing an unsent prompt?
- Should CodeCompanion support creating sessions without a host for
  server-local/headless agents?
- What is the generic model catalog protocol for Omnigent-compatible servers?
- Which elicitations should CodeCompanion render natively versus punting to
  Omnigent UI?
- How much of Omnigent's session tree should CodeCompanion expose initially?

## Acceptance Criteria

Native Omnigent support is complete when:

- CodeCompanion can create an Omnigent session on the correct host/workspace.
- CodeCompanion can submit foreground prompts and stream responses.
- CodeCompanion can cancel foreground turns.
- CodeCompanion can list and resume Omnigent sessions.
- CodeCompanion can render durable history from Omnigent items.
- CodeCompanion remains attached to a session and renders external wakeups while
  idle.
- CodeCompanion reconciles streams and history without duplicate turns.
- CodeCompanion exposes model/effort/status metadata.
- CodeCompanion supports pending elicitations safely.
- CodeCompanion surfaces child/sub-agent/background work enough that Omnigent's
  meta-harness behavior is visible and understandable.
