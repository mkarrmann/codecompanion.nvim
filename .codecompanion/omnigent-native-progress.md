# Omnigent Native Adapter — Implementation Progress

Status as of this session. Implements the design in
`omnigent-native-integration.md`, corrected by the empirically-captured contract
(fixtures under `.codecompanion/omnigent-fixtures/`).

---

## Handoff — start here (fresh agent)

**Reading order:**
1. **This doc** — current state + how to build/verify.
2. `omnigent-native-roadmap.md` — file-level task breakdown for everything left.
3. `.codecompanion/omnigent-fixtures/` (also copied to `tests/stubs/omnigent/`) —
   **ground truth for the wire contract**, captured from a live server.
4. `omnigent-native-integration.md` — the ORIGINAL design. **Aspirational and
   partly WRONG** (ids, dedup, reconnect, host taxonomy, model catalog). Trust the
   fixtures + this doc's "Corrected-contract decisions" over it.
5. Dotfiles adapter (already implemented): see `~/dotfiles/docs/omnigent-codecompanion-adapter.md`
   and `~/dotfiles/nvim/lua/plugins/codecompanion.lua` (`config.adapters.omnigent`, `<leader>aM`).

**Environment (this repo, on the user's Mac):**
- `deps/` is gitignored and must exist for tests. Recreate if missing:
  ```
  mkdir -p deps
  ln -sfn ~/.local/share/nvim/lazy/plenary.nvim deps/plenary.nvim
  git clone --filter=blob:none --depth=1 https://github.com/echasnovski/mini.nvim deps/mini.nvim
  ```
- **Do NOT use `make test`** — its `scripts/minimal_init.lua` installs tree-sitter
  parsers via a `tree-sitter` CLI that is NOT installed here (fails + noisy).
  Use the lean init below (skips tree-sitter; the protocol layer is pure Lua).
- No `stylua` installed → can't auto-format (new files hand-matched to repo style).
- Live omnigent server: `http://127.0.0.1:6767` (launchd), no local auth.

**Verify loop (inner):**
```
LC_ALL=C nvim --headless --noplugin -u tests/omnigent/minimal_init.lua \
  -c "lua MiniTest.run_file('tests/omnigent/test_handler.lua')"
```
**Run the whole omnigent suite (12 files, 113 cases):**
```
LC_ALL=C nvim --headless --noplugin -u tests/omnigent/minimal_init.lua -c "lua
for _,f in ipairs({'tests/omnigent/test_sse.lua','tests/omnigent/test_events.lua','tests/omnigent/test_client.lua','tests/omnigent/test_session.lua','tests/omnigent/test_render.lua','tests/omnigent/test_sessions.lua','tests/omnigent/test_observer.lua','tests/omnigent/test_reconnect.lua','tests/omnigent/test_elicitation.lua','tests/omnigent/test_controller.lua','tests/omnigent/test_handler.lua','tests/adapters/omnigent/test_adapter.lua'}) do MiniTest.run_file(f) end"
```
**Live milestone smoke (M3 list/format + M4 foreground/observer arbitration + M6 meta):**
```
OMNI_AGENT=polly LC_ALL=C nvim --headless --noplugin -u tests/omnigent/minimal_init.lua \
  -c "luafile tests/omnigent/live_smoke_milestones.lua" -c "qa!"
```
**Live smoke (creates one cheap real session; use a claude-sdk agent for text):**
```
OMNI_AGENT=polly LC_ALL=C nvim --headless --noplugin -u tests/omnigent/minimal_init.lua \
  -c "luafile tests/omnigent/live_smoke.lua" -c "qa!"
```

## Architecture / data flow

```
omnigent/sse.lua      raw SSE text -> decoded events (injectable; null->nil via luanil)
omnigent/events.lua   reducer: events -> normalized updates {kind,response_id?,...}
                      (STATEFUL: current_response_id, text accumulator, reset_inflight)
omnigent/client.lua   REST + SSE transport (INJECTABLE request/job); fail-closed host
                      resolution; opaque ids; pagination; null->nil decode
omnigent/session.lua  per-chat runtime (the acp.Connection analog): create/load,
                      STREAM ROUTER (foreground callback else observer), reconnect +
                      /items reconcile, heartbeat watchdog, seen_items, post/interrupt,
                      set_model, labels, pending_elicitations/child_sessions tracking
adapters/omnigent/    family factory (init.lua) + generic template (default.lua)
interactions/chat/omnigent/handler.lua     foreground glue: ensure_session (installs
                      observer when background_updates) -> RequestStarted -> stream -> post
                      -> render deltas/tool rows/elicitations -> _complete()+detach; resume()
interactions/chat/omnigent/observer.lua    M4 passive consumer: background turns, wakeups,
                      reconcile; single-current-turn + content-dedup
interactions/chat/omnigent/elicitation.lua M5 approval prompt + resolve
interactions/chat/omnigent/render.lua      durable item -> messages + meta lines + enrich_usage
interactions/chat/omnigent/sessions.lua    M3 pure list helpers (format/filter/sort)
interactions/chat/omnigent/controller.lua  M6 sessionful controller (submit/resume/close/meta)
interactions/chat/sessionful.lua           M6 registry (adapter.type -> controller)
chat/init.lua         dispatch delegates to the controller for _submit_omnigent /
                      resume_omnigent / close / update_metadata omnigent arms
```
Chat contract mirrors ACP: accumulate assistant chunks in `handler.output`, hand to
`chat:done(output, reasoning)`; `chat:add_buf_message` streams to the buffer.

## Key invariants — DO NOT regress (each caused a reviewer-found bug)

- **IDs are opaque** — never sniff `conv_`/`ag_` prefixes; resolve agent id-first-then-name.
- **Host fail-closed** — `host="auto"` refuses on zero/ambiguous match; `workspace="auto"`
  only sends cwd when the host is this machine; never leak local paths to a remote host.
- **Dedup = content/byte equality** — deltas carry NO ids; anchor the per-turn text
  accumulator on `current_response_id` from `response.created`/`in_progress`, and in the
  observer append only the new suffix beyond what was already shown.
- **JSON null → nil, never `vim.NIL`** — the client + sse decoders pass
  `{luanil={object=true}}` so a null field is absent, not the truthy `vim.NIL` sentinel
  (which would win every `field or default` chain — e.g. `llm_model:null` → a `vim.NIL`
  model, and would break `not body.has_more` pagination). `Session:_ingest_snapshot`
  also `nn()`-normalises defensively. Regressing this reintroduces the `model=vim.NIL` bug.
- **Stream-first reconnect (IMPLEMENTED, M4)** — in-flight text is replayed on `/stream`
  subscribe, NOT in `/items`. On reopen the reducer calls `reset_inflight()` so the replay
  rebuilds cleanly and the observer's suffix-dedup avoids a double-render. Reconnect is
  attempted ONLY when the observer (not a live foreground turn) owns the stream — the
  un-deduped foreground path must never see a replay. `/items` reconcile fills only turns
  that fully completed during the disconnect (skips `seen_items` + active partials).
- **Interrupt = `{"type":"interrupt","data":{}}`** (empty OBJECT); it does not stop/delete
  the session; `session.interrupted` (not `response.cancelled`) ends an interrupted turn.
- **Observer arbitration** — the session stream ROUTER sends each update to the foreground
  callback if bound, else the observer. Foreground submit binds it; completion detaches it;
  the observer resumes. Never render the same turn through both.
- **Handler MUST fire `RequestStarted` (before stream/post) + `RequestFinished` (paired)** —
  the user's input queue + spinners depend on them.
- **Handler MUST detach from the session on completion** — otherwise background/wakeup
  events render through a finished handler.
- **Resume = `OmnigentHandler:resume()`** (load + hydrate, no post). NEVER resume through
  `submit()`; a blank/no-unsent submit is a clean no-op (`ready_for_input`), not an error.
- **Hydration uses role-appropriate `MESSAGE_TYPES`** (`USER_MESSAGE` vs `LLM_MESSAGE`).
- **Native support is explicit** — the built-in `claude-native-ui` and
  `codex-native-ui` agents now normalize terminal output onto the session stream;
  other native harnesses remain unvalidated.
- **Adapter extend** — extend the family `"default"` via the family module
  (`require("codecompanion.adapters.omnigent").extend("default", {...})`); extending
  `"omnigent"` recurses and routing `"default"` through top-level `extend()` misfires to http.
- **omnigent owns tools server-side** — don't push CC's local tool registry (mcp start skipped).

## Milestones

- **M1 — Protocol client + adapter type: COMPLETE, verified (unit + live).**
- **M2 — Foreground chat: COMPLETE, verified (unit/integration + live protocol e2e).**
- **M3 — Resume/list/metadata: COMPLETE.** `update_metadata` omnigent fields
  (host/workspace/status/effort/usage/pending); `/omnigent_resume` picker +
  `/omnigent_session` info + `/omnigent_children` slash commands; `Chat.new`
  captures `omnigent_session_id`; `Chat:resume_omnigent()` entry; pure
  `interactions.chat.omnigent.sessions` list helpers (format/filter/sort);
  dotfiles `omnigent_continue()` picker + `<leader>amc`. Live-verified list+format.
- **M4 — Wakeups / passive streaming: COMPLETE.** Persistent `observer.lua`
  renders background turns while idle (content-dedup, single-current-turn model
  robust to the id-less-delta vs resp-id-completion mismatch); session stream
  ROUTER (foreground callback precedence, observer otherwise) — live-verified the
  observer stays dormant during a foreground turn; reconnect-on-drop +
  `reset_inflight` replay dedup + `/items` reconcile (skips seen items + active
  partials); heartbeat-timeout watchdog; `ChatOmnigentWakeup`/`BackgroundTurn`
  autocmds; scriptable `tests/omnigent/fake_server.lua` harness. Opt-in via
  `opts.background_updates` (dotfiles: on). Reconnect only when the observer (not a
  live foreground turn) owns the stream — avoids double-rendering the un-deduped
  foreground path.
- **M5 — Meta-harness (elicitations, tools, child sessions): COMPLETE.**
  `elicitation.lua` presents MCP-shaped elicitations via the shared
  `approval_prompt` (accept/decline/cancel + form fields from `requestedSchema`)
  and resolves via `session:resolve_elicitation`; wired into BOTH the foreground
  handler and the observer; pending tracked on the session (feeds
  update_metadata). Live tool calls render as compact rows; child sessions render
  inline + `/omnigent_children`; `policy_denied` rendered. Deferred (low value):
  inbox/task/timer meta rows.
- **M6 — Generic sessionful interface: COMPLETE (omnigent-only, per roadmap).**
  `interactions.chat.sessionful` registry + `interactions.chat.omnigent.controller`
  (submit/resume/set_model/close/session_meta); `chat/init.lua` omnigent branches
  delegate to it. ACP migration intentionally DEFERRED (its ~10 monkeypatches make
  it high-risk — a separate workstream).

### Track C — dotfiles lib parity: COMPLETE
Shared `lib/codecompanion-session.lua` `session_id(chat)` resolver (acp OR
omnigent); winbar `cc_session_id`, statusline, stats-eviction and doctor all route
through it; chatinfo pins on `OmnigentSessionReady`/`OmnigentChatRestored`; the
handler/observer fire a neutral `CodeCompanionOmnigentUsage` event (context_window
back-filled from the model catalog) which `codecompanion-stats` consumes for
context-%; reap stops the SSE stream on real teardown but EXEMPTS hidden omnigent
chats (so wakeups keep rendering while you look elsewhere); dotfiles toasts
`CodeCompanionChatOmnigentWakeup` for non-visible chats. Gotcha still true:
`context_window` may be null over SSE — the model-catalog fallback covers it when
the catalog carries it, else context-% degrades to plain "CC".

## Review-fix history (chronological — some points later superseded)

### M2-era review (foreground chat)
- **Lifecycle race** — `RequestStarted` fires BEFORE `start_stream`/`post`;
  post-failure routes through `_complete` so `RequestFinished` always pairs. (test)
- **Background leak** — the handler DETACHES from the session on completion
  (`_detach`), so post-turn/background stream events never render through a
  finished foreground handler. (test)
- **`load` fail-loud + pagination** — `Session:load` propagates item-fetch errors
  instead of returning `{}`; `Client:list_items` follows pagination. (test)
- **`stream_reconnect`** — was gated `false` as "M4-reserved". **SUPERSEDED by M4:**
  reconnect + `/items` reconcile is now implemented and safe (observer content-dedup +
  `reset_inflight`); enabled with `background_updates`/`stream_reconnect`.
- **Resume hydration** — the load path hydrates the transcript + buffer from durable
  items (`_hydrate` → `render.snapshot_messages`), marked sent. (test)
- **Elicitation (defensive)** — was a "resolve in the Omnigent UI" note.
  **SUPERSEDED by M5:** native elicitation handling (approval prompt + resolve).

### M2 review round 2 (resume correctness)
- **Bare resume no longer errors** — a blank/no-unsent submit is a clean no-op
  (`ready_for_input`), not `status="error"`. (test)
- **`OmnigentHandler:resume()`** — loads + hydrates history WITHOUT posting a turn
  (the M3 entry; `submit()` is only for new turns). (test)
- **Hydration uses role-appropriate buffer types** — user turns render as
  `USER_MESSAGE`, not `LLM_MESSAGE`. (test)

### M3–M6 review (final)
- **`vim.NIL` model bug** — a session field reported as JSON `null` decoded to the
  truthy `vim.NIL`, so `model_override or model or "default"` returned `vim.NIL`.
  Fixed at the decode boundary (`{luanil={object=true}}` in client + sse) plus a
  defensive `nn()` in `_ingest_snapshot`. This also fixed a latent
  `not body.has_more` pagination guard that was always false for `vim.NIL`. (test)
- Docs reconciled to the shipped state (this pass).

Current deferrals (see "Known limitations" above): M5 inbox/task/timer rows,
M6 ACP migration onto the sessionful interface, and GUI eyeball verification.

## New files

```
lua/codecompanion/omnigent/client.lua        REST+SSE client; fail-closed host resolution; opaque ids
lua/codecompanion/omnigent/sse.lua           Transport-agnostic SSE parser (injectable frame source)
lua/codecompanion/omnigent/events.lua        Stateful reducer -> normalised updates (+ reset_inflight)
lua/codecompanion/omnigent/session.lua       Per-chat runtime: stream router, reconnect+reconcile, heartbeat
lua/codecompanion/adapters/omnigent/init.lua     Adapter family factory
lua/codecompanion/adapters/omnigent/default.lua  Generic omnigent adapter template
lua/codecompanion/interactions/chat/omnigent/handler.lua     Foreground turn orchestration
lua/codecompanion/interactions/chat/omnigent/observer.lua    M4 passive/background-turn consumer
lua/codecompanion/interactions/chat/omnigent/render.lua      Durable-item -> message mappers + meta lines + enrich_usage
lua/codecompanion/interactions/chat/omnigent/sessions.lua    M3 pure session-list helpers (format/filter/sort)
lua/codecompanion/interactions/chat/omnigent/commands.lua    client_for(chat) helper
lua/codecompanion/interactions/chat/omnigent/elicitation.lua M5 elicitation UI + resolve
lua/codecompanion/interactions/chat/omnigent/controller.lua  M6 sessionful controller
lua/codecompanion/interactions/chat/sessionful.lua           M6 sessionful registry (omnigent-only)
lua/codecompanion/interactions/chat/slash_commands/builtin/omnigent_{resume,session,children}.lua
```

Dotfiles (Track C + M3 resume UX):
```
~/dotfiles/nvim/lua/lib/codecompanion-session.lua   shared session_id(chat) resolver (acp OR omnigent)
~/dotfiles/nvim/lua/plugins/codecompanion.lua       omnigent_continue() picker, <leader>amc, background_updates=on, wakeup toast, apply() stop_stream fix
~/dotfiles/nvim/lua/lib/{codecompanion-stats,chatinfo,statusline,reap,doctor}.lua  omnigent arms
~/dotfiles/nvim/lua/plugins/overrides.lua           winbar cc_session_id -> shared resolver
```

## Edited files (additive; existing families unaffected — ACP suite still green)

```
lua/codecompanion/adapters/init.lua          adapter_type + resolve/resolved/extend/make_safe/set_model omnigent arms
lua/codecompanion/config.lua                 config.adapters.omnigent = { omnigent = "default", ... }
lua/codecompanion/interactions/chat/keymaps/change_adapter.lua  picker merge + list_omnigent_models + select_model arm
lua/codecompanion/interactions/chat/init.lua _submit_omnigent, submit dispatch, start_mcp skip, change_model,
                                             close (stop_stream), update_metadata omnigent arm
```

## Tests (MiniTest) — 113 cases across 12 files, 0 fails

Run without the tree-sitter parser install (protocol layer is pure Lua):

```
nvim --headless --noplugin -u tests/omnigent/minimal_init.lua \
  -c "lua MiniTest.run_file('tests/omnigent/test_sse.lua')"
```

Files: `tests/omnigent/{test_sse,test_events,test_client,test_session,test_render,test_handler}.lua`,
`tests/adapters/omnigent/test_adapter.lua`. Fixtures copied to `tests/stubs/omnigent/`.

Note: the repo's `make test` uses `scripts/minimal_init.lua`, which installs
tree-sitter parsers via the `tree-sitter` CLI. That CLI is not installed on this
machine, so full chat-*render* / screenshot-golden tests cannot run here. The
lean `tests/omnigent/minimal_init.lua` skips tree-sitter for the omnigent unit
suite.

## Live validation (against a real omnigent at 127.0.0.1:6767)

`tests/omnigent/live_smoke.lua` (creates a real cheap session):

- list_agents=13, list_hosts=3; `resolve_host("auto")` fail-closed-resolved to
  this Mac uniquely.
- Full turn with a **claude-sdk** agent (`polly`): `completed: true`,
  `deltas: "ok"`, `item_committed`, `turn_completed` — the reducer processed real
  live events end-to-end.
- Older **claude-native-ui** validation observed no `output_text` deltas. Current
  Omnigent native forwarders normalize built-in Claude/Codex native output onto
  the session stream; retain SDK agents as fallbacks and validate native behavior
  on each supported host class.

## Corrected-contract decisions honored

- All ids treated as opaque strings (no `conv_`/`ag_` prefix sniffing); agents
  resolved id-first-then-name.
- Host resolution FAIL-CLOSED: `host="auto"` refuses on zero/ambiguous match
  rather than sending `host_id=nil`; `workspace="auto"` only sends cwd when the
  host is this machine; `host="none"` is the explicit headless opt-in.
- Dedup is content-based (deltas carry no ids); per-turn text anchored on
  `current_response_id` from `response.created/in_progress`; background delta with
  no open turn synthesises a background turn.
- Interrupt posts `{"type":"interrupt","data":{}}` (empty object) and does not
  stop/delete the session; `session.interrupted` (not `response.cancelled`) ends it.
- Phantom `turn.*` and `response.incomplete` events are dropped.

## Manual GUI verification checklist (what I could NOT verify headlessly)

Drive these in a real Neovim to confirm the buffer-facing behaviour:

1. Configure an omnigent adapter pointing at your server with a **claude-sdk**
   agent; open a chat with `adapter=omnigent` (`<leader>aM`); submit a prompt;
   confirm streamed assistant text renders in the buffer.
2. Cancel mid-turn (Ctrl-C) → confirm the turn stops and the session survives
   (resendable).
3. Confirm existing ACP adapters/customisations still work unchanged (regression).
4. `/model` picker lists omnigent models once a session exposes `model_options`.
5. **M3 resume:** `<leader>amc` (dotfiles picker) or `/omnigent_resume` in a fresh
   omnigent chat → pick a past session → confirm history hydrates (user vs
   assistant styled correctly) and the winbar pins its session id.
6. **M3 info:** `/omnigent_session` and `/omnigent_children` notify session detail.
7. **M4 wakeup:** with a session open, drive the SAME session from another client
   (or a scheduled wakeup) → confirm a "> [!NOTE] Omnigent background activity"
   block + streamed text appears while idle, and a toast fires if the chat is not
   the focused window. Kill the server's stream briefly → confirm it reconnects and
   does NOT double-render the in-flight message.
8. **M5 elicitation:** run an agent action that triggers an MCP elicitation →
   confirm the in-chat approval prompt appears; accept/decline/cancel resolves it
   and the turn proceeds (no hang). Confirm the pending count shows in metadata.
9. **Winbar/stats parity:** confirm the session pill + context-% (if the model
   catalog carries a context_window) render for omnigent chats.

## Known limitations / next steps (all milestones landed)

- **Async REST** — create/post/load are synchronous. They return <1s so it's not
  the ACP `session/new` freeze, but for polish you could wrap `_submit_omnigent`
  in `async_utils.sync` like the dotfiles ACP path. Not required.
- **M5 inbox/task/timer meta rows** — deferred (low value); the reducer surfaces
  them as `other` and they're dropped in rendering. Add render arms if wanted.
- **M6 ACP migration onto the sessionful interface** — deliberately NOT done
  (high-risk given the ~10 ACP monkeypatches). The registry + omnigent controller
  are in place; migrating ACP is a separate workstream.
- **context-% may be blank** — `session.usage.context_window` is often null over
  SSE; `render.enrich_usage` back-fills it from `session.model_options` when the
  catalog carries a `context_window`/`context_length`, else the winbar shows plain
  "CC" (no %). If needed, seed context_window from the session labels
  (`omnigent.last_context_window`).
- **GUI verification still manual** — `deps/` now contains `nvim-treesitter` +
  `parsers`, so the repo's screenshot-golden render tests MIGHT run via `make test`
  now (untested here); the omnigent logic layer is fully covered by the lean unit
  suite regardless. The buffer-facing render (headers, tool rows, elicitation
  prompt appearance) is the remaining eyeball check — see the checklist below.
```
