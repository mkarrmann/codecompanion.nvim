# Native Codex/Claude harness integration + Codex goals in CodeCompanion

Status: DRAFT / scoping
Owner: mkarrmann
Scope: `~/repos/codecompanion.nvim` (fork) + `~/dotfiles/nvim` (config). **No changes to `~/repos/omnigent`.**

## 1. Objective

1. Use the Omnigent **native UI harnesses** (`codex-native`, `claude-native`) as a
   CodeCompanion chat surface — rendering in the CC buffer, NOT the vendor TUI.
2. Expose **Codex goals** (`/goal`) from CodeCompanion chat: set / show / pause /
   resume / clear, with a live budget + token/usage indicator.

Constraint: achievable entirely as fork + config work. Omnigent core is used
as-is (read-only reference below).

## 2. Why native (and why goals force it)

Codex goals are **app-server thread state** (`thread/goal/{get,set,clear}` RPCs on
`codex app-server`), with a lifecycle (active/paused/blocked/usageLimited/
budgetLimited/complete) and telemetry (tokens_used, time_used, budget). Omnigent
does NOT mirror goal state into labels/rows — it is read/mutated only by talking
to the live app-server.

Omnigent exposes goals **only for codex-native sessions**:
- Routes: `GET/PUT/DELETE /v1/sessions/{id}/codex_goal`,
  `PATCH /v1/sessions/{id}/codex_goal/status`
  (`omnigent/server/routes/codex/sessions.py`, contract in
  `omnigent/server/codex-API.md`).
- Gate: `_require_codex_native_goal_session` rejects unless the session wrapper ==
  `codex-native-ui` (400 otherwise).
- Runner bridge: `omnigent/runner/codex/goal.py` forwards to app-server over the
  socket recorded in `CodexNativeBridgeState`.

The SDK `codex` harness runs the same app-server but over **private stdio owned by
the executor** — no out-of-band channel, and every SDK "live control"
(model/effort) is modelled as "persist to store, apply next turn," which a goal
cannot be. Adding goals to the SDK harness = net-new Omnigent core infra
(explicitly out of scope). Native already has the socket + persisted bridge +
wake/relaunch path goals need. => We adopt native.

## 3. Key discovery: native output already reaches the client as `response.*`

Native harnesses boot a vendor TUI in a tmux terminal on the runner, but a
forwarder mirrors their output into the AP session stream, and **the AP server
translates those `external_*` events into the exact `response.*` SSE events the
SDK path emits** (`omnigent/server/routes/sessions.py`):

| Forwarder event (`external_*`)          | Client `/stream` SSE (`response.*`)                         |
|-----------------------------------------|-------------------------------------------------------------|
| `external_output_text_delta`            | `response.output_text.delta`                                |
| `external_tool_output_delta`            | `response.function_call_output.delta`                       |
| `external_output_reasoning_delta`       | `response.reasoning.started` + `response.reasoning_text.delta` |
| `external_conversation_item`            | persisted item -> `response.output_item.done`               |
| `external_session_status`               | status edges (running/idle)                                 |
| `external_session_usage`                | usage                                                       |
| `external_model_change` / `..._effort_change` | model / effort change                                 |
| `external_elicitation_resolved`         | elicitation resolved                                        |
| `external_session_interrupted`          | interruption                                                |

Emitters: `omnigent/codex_native_forwarder.py` (full delta set),
`omnigent/claude_native_forwarder.py` (deltas via message-display-hook file +
`external_conversation_item`).

**Implication:** the fork's existing parser (`lua/codecompanion/omnigent/events.lua`,
which already handles `response.output_text.delta`, `response.reasoning_text.delta`,
`response.output_item.done`, `response.completed`, ...) should render native
sessions with little/no change. The old empirical "native renders nothing" note
in the dotfiles is most likely a **launch/host-binding** problem
("codex-native-ui fails to start"), not a rendering gap — Phase 0 confirms this.

Sending a turn to a native session is already supported: the runner `message`
handler notes a native turn start and delivers via the continuation drain / TUI
injection (`omnigent/runner/app.py:post_session_events`).

## 4. What already exists in the fork

- Adapter machinery supports native agents TODAY: `adapters/omnigent/default.lua`
  ships `agent = "claude-native-ui"`, with fail-closed `host`/`workspace`
  binding (`omnigent/session.lua:resolve_host`).
- Generic REST client (`omnigent/client.lua`) already has `get/put/patch/delete`
  + `post_event`, `_list_all`, `stream_session`, `resolve_agent/resolve_host`.
  It can call the `codex_goal` routes with zero transport work.
- SSE + turn pipeline (`omnigent/sse.lua`, `omnigent/session.lua`,
  `interactions/chat/omnigent/{handler,render,observer,controller}.lua`).

What blocks native today = **config**: the dotfiles picker filter
`_omnigent_is_chat_harness` (in `nvim/lua/plugins/codecompanion.lua`) excludes
every `*-native` harness from the agent picker.

## 5. The central tradeoff (decision required)

Native-ui agents **run host-side in a bypass / permission-less mode and never
surface elicitations/approvals to the client** (documented in
`adapters/omnigent/default.lua`). So:

- With native harnesses, CodeCompanion is NOT the approval authority. Tool calls
  run without client-side gating (host-side posture / bypass). The elicitation
  card flow that the SDK `claude-sdk` path uses does not fire.
- If client-side approval gating is a hard requirement, native is the wrong
  surface and goals would instead require the Omnigent-core SDK route (out of
  scope here).

Decision needed (see Open Questions): is bypass-mode acceptable for these
sessions?

Other native costs: a real tmux TUI process per session on the host (heavier),
and mirror fidelity depends on the forwarder (validate in Phase 0). claude-native
streams deltas via a hook file (slightly lossier ordering than codex-native's
direct deltas).

## 6. Approach

Add native harnesses as an **additional** chat path (do not replace the SDK
omnigent default). Keep `<leader>aA`/`aM` on SDK; add a native launch path and a
`/goal` slash command usable in any codex-native chat.

### Phase 0 — Spike / validate assumptions (no code) ~0.5 day
- Launch a `codex-native-ui` and a `claude-native-ui` session against the local
  omnigent server; confirm they start (root-cause any "fails to start": host
  binding, workspace, tmux/codex/claude CLI availability on the runner host).
- `curl -N .../v1/sessions/{id}/stream` while sending a turn; confirm the client
  receives `response.*` events (text/reasoning/tool/item/status/usage).
- Point the existing CC omnigent adapter at a native agent (temporary config)
  and observe rendering fidelity in the buffer: text, reasoning, tool cards,
  final item commit, interrupt.
- `curl` the goal routes on the codex-native session: GET (null), PUT (set),
  PATCH status (pause/resume), GET (verify), DELETE.
- OUTPUT: a short findings note appended here (works / gaps / fidelity issues).

### Phase 1 — Enable native harnesses in the picker + fix rendering gaps ~0.5-1 day
- Config (`nvim/lua/plugins/codecompanion.lua`): stop excluding `*-native` from
  the picker. Prefer a *separate* pick path so the SDK default is preserved:
  - keep `_omnigent_is_chat_harness` for the SDK picker,
  - add a native picker (or a flag on the picker) offering `codex-native` /
    `claude-native`, wired to a new keybinding (e.g. `<leader>aN`... pick an
    unused one; audit current `a*` map first).
- Fork: only if Phase 0 surfaced gaps — extend `events.lua`/`handler.lua`/
  `render.lua`. (Expected: minimal, since translation is server-side.)
- Explicitly handle/annotate the no-elicitation posture (e.g. a one-time notice
  in-buffer when a native session is opened, so the bypass posture is visible).

### Phase 2 — Codex goals ~1-1.5 days
- Client (`omnigent/client.lua`): add
  - `codex_goal_get(session_id)` -> GET
  - `codex_goal_set(session_id, {objective, token_budget?, status?})` -> PUT
  - `codex_goal_update_status(session_id, status)` -> PATCH /status
  - `codex_goal_clear(session_id)` -> DELETE
  (thin wrappers over `Client:request`; normalize the `{goal=...}` /
  `{cleared=...}` envelopes + the documented error codes 400/403/404/503).
- Slash command
  (`interactions/chat/slash_commands/builtin/codex_goal.lua`): `/goal` with
  subactions — `set` (prompt objective, optional budget), `show`, `pause`,
  `resume`, `clear`. Guard: only enabled for codex-native chats (harness check
  via the live session; friendly message otherwise). Reuse
  `interactions/chat/omnigent/commands.lua:client_for(chat)`.
- Live indicator: poll `codex_goal_get` on an interval (config, e.g. 10s) while a
  goal is active, rendering objective + status + `tokens_used/token_budget` +
  time in a virtual-text / winbar / statusline slot. Stop polling when no goal /
  chat closed. (Goal state is NOT streamed — polling is the supported pattern.)
- Config: keybinding for `/goal` (e.g. under the `a*` chat group) + any goal poll
  settings surfaced in the adapter `opts`.

### Phase 3 — Native control parity (optional, after goals) ~0.5-1 day
- Verify model/effort switching works for native via the existing
  `<leader>ao`/`<leader>aM` paths (server forwards `model_change`/`effort_change`
  to native harnesses already). Adjust the omnigent family/model pickers if
  native needs different model id handling.
- Optional: Codex plan-mode toggle (`external_codex_collaboration_mode_change` /
  the plan_mode_change route), compact/interrupt parity.

### Phase 4 — Polish ~0.5 day
- Docs (fork `doc/` + a note in dotfiles), keybinding help, defensive errors
  (offline runner 503 with wake, host-bind failures), tests/fixtures for the
  goal client + `/goal` command and for `external_*`-derived `response.*`
  rendering if any parser changes were needed.

## 7. Files (reference vs change)

Omnigent (reference ONLY — do not modify):
- `omnigent/server/codex-API.md` — goal REST contract
- `omnigent/server/routes/codex/sessions.py` — goal routes + native gate
- `omnigent/runner/codex/goal.py` — runner->app-server goal bridge
- `omnigent/server/routes/sessions.py` — `external_* -> response.*` translation, `_ALLOWED_EVENT_TYPES`
- `omnigent/{codex,claude}_native_forwarder.py` — TUI->stream mirror
- `omnigent/harness_plugins.py` — `CODEX_NATIVE_CODING_AGENT` (wrapper `codex-native-ui`)

Fork (change):
- `lua/codecompanion/omnigent/client.lua` — goal methods (Phase 2)
- `lua/codecompanion/interactions/chat/slash_commands/builtin/codex_goal.lua` — new `/goal` (Phase 2)
- `lua/codecompanion/interactions/chat/omnigent/{handler,render}.lua` — only if Phase 0 finds gaps
- `lua/codecompanion/omnigent/events.lua` — only if Phase 0 finds gaps
- `lua/codecompanion/adapters/omnigent/default.lua` — (already native-capable; maybe doc/opts for goal poll)

Config (change):
- `~/dotfiles/nvim/lua/plugins/codecompanion.lua` — picker filter, native pick path, keybindings (`/goal`, native launch), goal poll opts

## 8. Goal REST contract (from codex-API.md)

- `GET /codex_goal` -> `{ "goal": { thread_id, objective, status, token_budget|null,
  tokens_used, time_used_seconds, created_at|null, updated_at|null } | null }`
- `PUT /codex_goal` <- `{ objective (<=4000, req), token_budget?(int>0|null), status?(active|paused) }`
- `PATCH /codex_goal/status` <- `{ status: active|paused }`
- `DELETE /codex_goal` -> `{ "cleared": true }`
- Errors: 400 (not native / bad input), 404, 403 (can read but can't wake offline
  host-bound runner), 503 (no live runner / malformed).

## 9. Risks

- R1: Approvals/elicitations do NOT surface for native (bypass posture). Blocking
  if client gating is required. => Open Q1.
- R2: Mirror fidelity (tool cards / reasoning ordering, esp. claude-native's
  hook-file deltas). => Phase 0 validates.
- R3: "codex-native-ui fails to start" — host binding / runner env. => Phase 0.
- R4: Offline-session goal ops need edit access to wake a host-bound runner (403
  path). Surface clearly.
- R5: Extra runtime cost (tmux TUI per session).

## 10. Open questions

1. **Approvals**: is host-side bypass/permission-less execution acceptable for
   these native sessions? (If not, native is unsuitable and goals need an
   Omnigent-core change instead.)
2. **Replace vs augment**: native as an additional pick path (recommended) or the
   new default for chat?
3. **Host/workspace**: always local host, or remote devserver hosts too?
4. **Goal UX**: subcommands (`/goal set|show|pause|resume|clear`) + indicator
   surface (winbar vs virtual text vs statusline) + poll interval?
5. **Claude native goals**: goals are Codex-only. Is claude-native wanted purely
   as a chat surface (no goals), or deprioritized?
