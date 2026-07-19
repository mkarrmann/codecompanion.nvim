# Omnigent Native Harnesses and Codex Goals

## Status

Implemented on the Linux devserver; macOS and cross-integration validation
remain. The scope integrates Omnigent's built-in `claude-native-ui` and
`codex-native-ui` agents into CodeCompanion and exposes Codex Goal controls in
an Omnigent-backed chat.

This work changes only:

- `~/repos/codecompanion.nvim`
- `~/dotfiles`

It does not require an Omnigent fork or changes to Omnigent itself. It consumes
the native-session and Codex Goal APIs already exposed by the installed
Omnigent server.

## Devserver Contract Findings

Live validation on 2026-07-19 established these ordering details:

- Both built-in native agents accept ordinary session message events and
  persist assistant output.
- The message POST first produces an empty native `response.in_progress` /
  `response.completed` queue acknowledgement. That acknowledgement is not the
  model turn and must not finish CodeCompanion's foreground request.
- `session.input.consumed.cleared_pending_id` correlates the real native turn
  with the POST response's `pending_id`.
- Codex-native forwards `response.output_text.delta` before the committed
  assistant item. Claude-native may forward only `response.output_item.done`;
  CodeCompanion therefore renders committed assistant text when no delta was
  seen.
- The terminal-backed turn completes at the later `session.status=idle` edge,
  after the correlated input was consumed and native output began.
- `PUT /codex_goal` starts Goal execution immediately. A live test streamed the
  assistant result, transitioned the Goal to `complete`, exposed token/time
  usage through `GET`, and cleared it through `DELETE`.
- Goal GET and mutations work through the asynchronous client path without
  blocking Neovim.

Approval allow/deny, Google Chat, runner restart, macOS, and remote-host resume
remain acceptance-suite work; the streaming SDK agents stay available as
fallbacks.

## Decision

Use Omnigent's existing built-in native agents as first-class choices in the
CodeCompanion Omnigent adapter:

- `claude-native-ui` (`harness=claude-native`)
- `codex-native-ui` (`harness=codex-native`)

CodeCompanion remains the chat renderer and input surface. Omnigent may still
create a terminal resource because that is part of the native harness
lifecycle, but CodeCompanion does not attach to or render that terminal.
Instead it continues to use the same durable session APIs it uses today:

```text
CodeCompanion
  -> POST /v1/sessions/{id}/events
  <- GET  /v1/sessions/{id}/stream
  <- GET  /v1/sessions/{id}/items
```

The native forwarders are responsible for translating the vendor session into
normal Omnigent messages, tool calls, reasoning, usage, status, and
elicitations. CodeCompanion renders those normalized events.

Keep the existing streaming `claude-sdk` and `codex` agents available during
rollout. Native agents become additional choices, not silent replacements. A
later default change requires the live acceptance suite in this document to
pass on both macOS and devservers.

## Why This Approach

The normal Omnigent `codex` harness and `codex-native` both use Codex app-server,
but Omnigent currently exposes its Codex-specific session control plane only
for sessions stamped as `codex-native-ui`. In particular, the existing public
API provides:

```text
GET    /v1/sessions/{id}/codex_goal
PUT    /v1/sessions/{id}/codex_goal
PATCH  /v1/sessions/{id}/codex_goal/status
DELETE /v1/sessions/{id}/codex_goal
```

Using the built-in native agent gives CodeCompanion access to those endpoints
without reaching into runner-local app-server sockets or adding Omnigent server
routes.

An Omnigent community harness plugin is not an alternative for this work. The
plugin interface cannot override a built-in harness, add server routes, or
register native terminal lifecycle metadata. A sidecar that reaches into a
runner's private Codex socket would also break host routing, wakeup, auth, and
resume boundaries already handled by Omnigent.

## Current State

The CodeCompanion fork already provides the required harness-neutral substrate:

- Omnigent REST and SSE client
- durable session create/load/resume
- foreground and background stream arbitration
- reconnect and durable-item reconciliation
- normalized message, reasoning, tool, child-session, and elicitation events
- model and effort mutation
- interrupt handling
- session metadata, winbar, context usage, and hidden-chat wakeups

The dotfiles picker currently excludes every harness ending in `-native`. That
filter was added after older live tests in which native sessions did not emit
chat text. The current Omnigent server now persists normalized user and
assistant messages for both built-in native agents, including Codex-native tool
calls. The old observation must be replaced with explicit current-version live
tests rather than retained as an invariant.

The CodeCompanion Omnigent client does not yet wrap the Codex Goal endpoints,
does not retain native wrapper labels or harness identity in its session state,
and has no Goal command or display.

## Goals

1. Launch new Claude-native and Codex-native Omnigent sessions from the existing
   CodeCompanion agent picker.
2. Render native sessions entirely through the CodeCompanion chat buffer.
3. Preserve resume, background updates, reconnect, approvals, interrupts,
   model/effort controls, Google Chat, and Orchest attribution.
4. Provide a CodeCompanion Goal UI for eligible Codex-native sessions.
5. Support Goal create/replace, inspect, pause, resume, and clear operations.
6. Surface enough Goal state to understand whether the goal is active, paused,
   blocked, limited, or complete.
7. Keep the change reversible and retain the existing streaming harnesses.

## Non-Goals

- Changing Omnigent's Goal API or extending it to the normal `codex` harness.
- Suppressing creation of the native terminal resource.
- Rendering an embedded TUI in Neovim.
- Implementing Goal support for Claude. Goal is a Codex feature.
- Recreating Codex Goal persistence or lifecycle in Lua.
- Sending CodeCompanion's local tool registry to native agents. Native agents
  own their tool surface and receive Omnigent integrations through the existing
  MCP and policy bridges.
- Making either native agent the default before cross-host live validation.
- Implementing every native-only Omnigent web control in the first change. Plan
  mode, terminal attach, native fork controls, and richer MCP startup UI can be
  separate follow-ups.

## Native Session Contract

### Agent Selection

Do not remove the native filter globally. Admit only the two built-in agents
whose chat forwarding is in scope:

```text
claude-native-ui  harness=claude-native
codex-native-ui   harness=codex-native
```

Other `*-native` harnesses remain hidden until independently validated. Match on
the server-provided harness plus the known built-in agent name. Do not infer
support from a name alone.

The existing Omnigent selection cache remains a triple:

```text
{ agent, model, effort }
```

Native Claude and Codex reuse the existing family-specific model and effort
pickers. No new parallel cache is needed.

### Session Identity and Capabilities

Extend `CodeCompanion.Omnigent.Session` to retain these snapshot fields:

```lua
harness = "codex-native"
agent_name = "codex-native-ui"
labels = {
  ["omnigent.wrapper"] = "codex-native-ui",
  ["omnigent.ui"] = "terminal",
}
```

Capability checks must use server-owned session metadata, not the adapter's
initial selection cache. Resumed sessions and sessions switched by another
client may not match the current cache.

Codex Goal support is enabled only when:

```text
session.labels["omnigent.wrapper"] == "codex-native-ui"
```

This matches Omnigent's API authorization gate. `harness=codex-native` can be
shown as diagnostic context, but it is not sufficient by itself because a
custom chat-first native agent is not currently accepted by the Goal routes.

### Input and Output

Continue posting ordinary Omnigent message events. Omnigent routes native
messages through the native runner and lets its transcript forwarder be the
single durable writer. CodeCompanion must not special-case native messages by
posting a second durable copy.

The existing handler already marks the local user message sent after the POST
succeeds. Tests must cover the native response shape, including a returned
`pending_id` with no immediately persisted item id.

The reducer should remain based on normalized Omnigent events, not vendor event
names. Add fixture coverage for the actual Claude-native and Codex-native event
sequences. Unknown native events remain visible as compact rows or explicitly
ambient; they must not terminate the foreground request accidentally.

### Native Ownership Differences

Native executors ignore the ordinary agent-spec system prompt and tool list.
The effective behavior comes from vendor configuration, Codex/Claude rules,
native skills and tools, and Omnigent's MCP/policy bridges. This is an expected
semantic difference from `claude-sdk` and the normal `codex` harness and must be
documented in the picker/help text.

## Codex Goal Design

### API Client

Add typed wrappers to `lua/codecompanion/omnigent/client.lua`:

```lua
Client:get_codex_goal(session_id)
Client:set_codex_goal(session_id, goal)
Client:update_codex_goal_status(session_id, status)
Client:clear_codex_goal(session_id)
```

Wire field names follow Omnigent's API:

```lua
goal = {
  thread_id = "...",
  objective = "...",
  status = "active",
  token_budget = 40000, -- or nil
  tokens_used = 1200,
  time_used_seconds = 180,
  created_at = 1776272400, -- or nil
  updated_at = 1776272460, -- or nil
}
```

Only `active` and `paused` are client-writable statuses. Values such as
`blocked`, `usageLimited`, `budgetLimited`, and `complete` are Codex-owned and
read-only.

Goal GET and mutation can wake an offline native runner. These operations must
not block Neovim's UI on the existing synchronous REST path. Add an asynchronous
request path or run the Goal workflow through an existing async abstraction.
Keep the transport injectable so unit tests do not require a live server.

### Session API

Add session-level methods that validate session readiness and capability before
calling the client:

```lua
Session:supports_codex_goal()
Session:get_codex_goal()
Session:set_codex_goal(goal)
Session:set_codex_goal_status(status)
Session:clear_codex_goal()
```

Cache the most recently returned goal in `session.codex_goal` for metadata and
display. The Omnigent server does not mirror Goal state into the session
snapshot or SSE stream, so this cache is advisory and must be refreshed before
presenting an edit dialog.

Do not introduce continuous polling initially. Refresh:

- when the Goal UI opens;
- after every Goal mutation;
- optionally after a native turn completes while a goal is known to be active.

Continuous progress polling can be added later if on-demand state proves
insufficient.

### Chat UX

Add a CodeCompanion-local `/goal` slash command. It is visible only for an
Omnigent adapter that either:

- has an attached session that passes `supports_codex_goal()`; or
- is configured to create a `codex-native-ui` session.

`/goal` must work as the first action in a newly opened chat. If no session
exists yet, the command creates one through the existing Omnigent session
resolution path, installs the background observer, and then validates the
server-returned wrapper label before showing Goal controls. It must not submit a
dummy prompt merely to force session creation.

Expose this bootstrap through the sessionful controller instead of constructing
an `OmnigentHandler` inside the slash command. Foreground submit and Goal-first
session creation must share host resolution, workspace validation, labels,
metadata events, and error handling.

Opening `/goal` first fetches current state, then presents actions appropriate
to that state.

No current goal:

```text
Create goal
```

Existing goal:

```text
View
Edit objective/budget
Pause            (when active)
Resume           (when paused, blocked, or limited)
Clear
```

Create/edit prompts for:

1. objective, required, trimmed, at most 4000 characters;
2. optional positive token budget, where blank means no budget;
3. initial mode, active by default with paused available.

The UI must show objective, status, token use versus budget, and elapsed time.
Errors remain in the command UI and do not add a fake user or assistant message
to the transcript.

The command is a client control, not prompt text. It must call the REST API
directly rather than sending `/goal` to the model as an ordinary message.

Expose the same operation through a Lua entry point so dotfiles can add a keymap
or action-palette item without duplicating the workflow. A new global keymap is
optional; `/goal` is the initial required surface.

### Goal Execution Contract Spike

Before finalizing the UX, verify against the installed Codex/Omnigent versions:

1. whether `PUT codex_goal` immediately starts Goal execution or only stores the
   objective for the next turn;
2. whether automatic continuation turns appear as normal response lifecycles on
   the session SSE stream;
3. how pause behaves during an active turn;
4. which status is returned after completion, blocking, usage limiting, and
   token-budget exhaustion;
5. whether waking an offline runner preserves the same thread and Goal state.

Do not make CodeCompanion post the objective as a second user message unless the
contract spike proves that setting the goal alone does not initiate work. A
blind PUT-plus-message implementation could execute the objective twice.

## CodeCompanion Changes

### Protocol and State

- Add asynchronous Codex Goal client methods.
- Retain `agent_name`, `harness`, and `labels` from session snapshots.
- Add Goal capability and session methods.
- Add a sessionful-controller ensure operation so a control command can create
  and attach a session without posting a chat turn.
- Add native snapshot and SSE fixtures from the current server contract.
- Ensure JSON null fields remain Lua `nil`.

### Chat and Rendering

- Add `/goal` and its state-dependent action UI.
- Add current Goal status to `/omnigent_session` when cached.
- Keep Goal-generated continuation turns on the existing background observer.
- Verify `RequestStarted`/`RequestFinished` pairing for the initiating turn and
  ensure later automatic turns do not incorrectly advance the input queue.
- Render native function calls through the existing `OmnigentToolCall` event so
  diff tracking and task attribution continue to work.
- Classify native-only durable items deliberately instead of emitting noisy
  unknown-event rows for expected terminal setup events.

### Documentation Cleanup

Update stale statements in:

- `.codecompanion/omnigent-native-progress.md`
- `lua/codecompanion/adapters/omnigent/default.lua`
- `~/dotfiles/docs/omnigent-codecompanion-adapter.md`
- `~/dotfiles/nvim/lua/plugins/codecompanion.lua`

Those files currently state that native agents cannot stream or render in
CodeCompanion. Replace that claim with the current contract and validation
requirements.

## Dotfiles Changes

### Agent Picker

Change `_omnigent_pickable_agents()` so it includes:

- all currently supported streaming agents;
- `claude-native-ui` only when its harness is `claude-native`;
- `codex-native-ui` only when its harness is `codex-native`.

Continue excluding every other native harness.

Labels currently added by the adapter must remain unchanged:

```text
omnigent.google_chat.enabled=true
orchest.nvim_session=<nvim session>
orchest.tab=<tab name>
```

Omnigent merges its own `omnigent.wrapper` and `omnigent.ui` labels into these
for built-in native agents.

### Launch UX

Keep the existing meanings:

- `<leader>aM`: reuse remembered Omnigent agent/model/effort;
- `<leader>aA`: pick Omnigent agent/model/effort;
- `<leader>aG`: pick the top-level path, including Omnigent.

Native Claude and Codex appear inside the Omnigent agent picker. Do not add two
more global launch mappings unless repeated use shows a real ergonomic need.

The picker must label native choices clearly, for example:

```text
claude-native-ui  - Claude native session (terminal-backed, chat-rendered)
codex-native-ui   - Codex native session (Goal support)
```

### Model and Effort

Reuse the current Claude and Codex family catalogs. Validate model identifiers
against live native sessions because native Codex route ids and Claude model ids
may differ from gateway-facing aliases.

The existing `<leader>ao` live model/effort workflow remains. For native Codex,
Omnigent applies updates through `thread/settings/update`; CodeCompanion should
consume the resulting session model/effort events as it does today.

## Integration Compatibility

### Google Chat

No bridge changes should be required. The bridge discovers sessions from labels,
reads the generic session stream, and posts generic message/interrupt events.
Omnigent performs native-specific routing behind those APIs.

Validation must cover:

- a phone reply reaching a native session;
- native output returning to the same Chat thread;
- Goal continuation output being mirrored after CodeCompanion is unfocused;
- `!stop` interrupting a native turn;
- approval-needed status remaining actionable in an Omnigent UI.

### Orchest

No mapping change should be required. Preserve `orchest.nvim_session` and
`orchest.tab`; verify native presentation labels are merged rather than replacing
them. Session and workspace attribution remains based on the same Omnigent
session id, host, workspace, and labels.

### CodeCompanion Queue, Winbar, and Stats

The existing sessionful controller remains authoritative. Native sessions use
the same session id, status, usage, and observer paths. Validate:

- one queue completion for one foreground request;
- background Goal turns do not consume unsent input;
- hidden-chat wakeup notifications remain deduplicated;
- context percentage uses native usage/model metadata when available;
- closing or changing adapters stops only the editor's SSE subscription, not
  the durable native session or active Goal.

### Approvals and Policies

Native agents route tool controls through Omnigent's native policy/MCP bridge,
not CodeCompanion's local tool registry. CodeCompanion continues to resolve
Omnigent elicitations through the existing approval UI. Validate both allow and
deny outcomes; do not silently enable bypass behavior to make a test pass.

## Implementation Sequence

### Phase 0: Capture Current Contracts

- Refresh OpenAPI and event fixtures from the installed Omnigent server.
- Capture one successful Claude-native and one successful Codex-native turn.
- Capture native tool call, approval, interrupt, reconnect, and resume sequences.
- Complete the Goal execution contract spike.

Exit criterion: fixtures prove that both native agents produce renderable
durable items and live lifecycle events on supported hosts.

### Phase 1: Native Agents in Existing Chat

- Store native session identity/capability fields.
- Add the two native agents to the dotfiles picker allowlist.
- Update stale documentation and comments.
- Verify foreground, resume, observer, model/effort, approval, and interrupt
  behavior without Goal support.

Exit criterion: both native agents are usable for ordinary CodeCompanion chat
without regressions to streaming Omnigent or ACP adapters.

### Phase 2: Codex Goal Controls

- Add asynchronous Goal client and session methods.
- Add `/goal` with create/view/edit/pause/resume/clear flows.
- Add cached Goal metadata to `/omnigent_session`.
- Route automatic Goal turns through the existing observer.

Exit criterion: a Codex-native session can complete the full Goal lifecycle from
CodeCompanion without terminal interaction.

### Phase 3: Cross-Integration Validation

- Test on macOS-local and devserver-hosted sessions.
- Test Google Chat reply, output mirror, and stop.
- Test Orchest labels and workspace attribution.
- Test runner restart, Neovim restart, resume, and Goal state recovery.
- Test adapter switching while a Goal remains active.

Exit criterion: the compatibility matrix passes and no integration depends on
the TUI being visible.

### Phase 4: Default Decision

After a trial period, decide independently whether native Claude and native
Codex should replace their streaming counterparts as defaults. This is a
configuration decision, not part of the initial implementation.

## Test Plan

### Unit Tests

- Native-agent allowlist accepts exactly the two intended agent/harness pairs.
- Session snapshot ingests `agent_name`, `harness`, and labels.
- Goal capability rejects streaming Codex, Claude-native, missing labels, and
  custom native sessions without the required wrapper label.
- Goal-first bootstrap creates a Codex-native session without posting a message
  and rejects a server snapshot whose wrapper is not Codex-native.
- Goal client constructs GET, PUT, PATCH, and DELETE requests correctly.
- Token budget preserves omitted versus explicit null semantics.
- Only `active` and `paused` can be written.
- Goal API errors are normalized and displayed without transcript mutation.
- `/goal` action availability matches current state.
- Native pending-input responses do not duplicate user messages.
- Native SSE fixtures normalize to the existing update types.

### Fake-Server Integration Tests

- Create and run a Claude-native session.
- Create and run a Codex-native session with function calls.
- Resume each session and hydrate durable history.
- Interrupt and reconnect without duplicate output.
- Set a Goal, observe continuation output, pause, resume, and clear.
- Simulate runner wakeup latency without blocking the Neovim event loop.
- Verify an active Goal continues through the background observer after the
  foreground handler detaches.

### Live Tests

- Linux devserver: Claude-native and Codex-native new sessions.
- macOS host: Claude-native and Codex-native new sessions.
- Model and effort changes before first turn and during a session.
- Tool call with approval and tool call denied by policy.
- Stop during reasoning/tool execution.
- Goal with and without token budget.
- Goal pause/resume and completion.
- Close Neovim, let Goal progress, reopen and resume without duplicate history.
- Reply from Google Chat while CodeCompanion is attached and while detached.
- Confirm Google Chat and Orchest labels survive native label stamping.

## Acceptance Criteria

- Both built-in native agents can be selected and launched from the existing
  Omnigent picker.
- Their user messages, assistant text, reasoning, tool calls, and completion
  status render in CodeCompanion without a visible terminal.
- Existing streaming Omnigent and ACP paths remain unchanged and tested.
- Resume, background updates, reconnect, approvals, interrupts, model/effort,
  winbar, and usage stats work for native sessions.
- `/goal` is available only on eligible Codex-native sessions.
- Goal create/view/edit/pause/resume/clear works without sending slash text to
  the model.
- Goal-generated turns render through the existing background observer without
  corrupting the input queue or duplicating messages.
- Google Chat can drive and mirror native sessions.
- Orchest and Google Chat labels remain present.
- Runner wakeups and Goal API calls do not freeze Neovim.
- No Omnigent source changes are required.

## Risks and Mitigations

### Native Event Contract Drift

Mitigation: capture current fixtures first and normalize only stable Omnigent
events. Keep vendor-specific details out of the reducer.

### Historical Native Startup Failures

Mitigation: explicit allowlist, keep streaming fallbacks, and require live tests
on every host class before changing defaults.

### Duplicate Input or Output

Mitigation: preserve Omnigent's native single-writer contract, test `pending_id`
responses, and reuse the existing stream-first reconnect deduplication.

### Goal State Is Not Streamed

Mitigation: refresh on command open and after mutations; avoid speculative
continuous polling in the first version.

### Goal Wakeup Blocks the Editor

Mitigation: make Goal calls asynchronous from the outset and test delayed runner
wakeup explicitly.

### Native Tool and Prompt Semantics Differ

Mitigation: present native agents as explicit choices, document that vendor
rules/tools are authoritative, and do not silently replace existing agents.

## Open Questions Resolved During Phase 0

1. Does `PUT codex_goal` itself start work on the installed Codex version?
2. Which live events delimit each automatic Goal continuation turn?
3. Does native Claude emit incremental deltas on every supported host, or only
   durable completed messages on some versions?
4. Does Goal pause interrupt the current turn or only prevent the next automatic
   turn?
5. Which Goal statuses should trigger an automatic refresh or user
   notification?
6. Are current curated model ids valid for both native harnesses on macOS and
   Linux?

These are contract-verification questions, not reasons to change Omnigent. If a
required behavior is absent from the installed public API, stop and reassess
rather than reaching into private runner state.

## Phase 0 Findings (2026-07-19)

- Both built-in native agents accept ordinary messages and persist assistant
  replies on the devserver host.
- Native input delivery emits an empty queue-level `response.completed` before
  the real terminal-backed turn. Claude may also emit idle edges before
  `session.input.consumed`. Client completion must therefore correlate the
  returned `pending_id` and finish on the real native idle edge.
- Codex emits `response.output_text.delta`; Claude can provide only the committed
  assistant item, so committed message text is the required no-delta fallback.
- `PUT codex_goal` starts work immediately. Goal output uses the normal session
  stream, the tested goal reached `complete`, usage was returned by `GET`, and
  `DELETE` cleared it. Sending the objective as a second message is incorrect.
- Goal REST wakeup works asynchronously through the public Omnigent API; no
  runner-local socket access or Omnigent source change is required.
