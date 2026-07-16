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
**Run the whole omnigent suite:**
```
LC_ALL=C nvim --headless --noplugin -u tests/omnigent/minimal_init.lua -c "lua
for _,f in ipairs({'tests/omnigent/test_sse.lua','tests/omnigent/test_events.lua','tests/omnigent/test_client.lua','tests/omnigent/test_session.lua','tests/omnigent/test_render.lua','tests/omnigent/test_handler.lua','tests/adapters/omnigent/test_adapter.lua'}) do MiniTest.run_file(f) end"
```
**Live smoke (creates one cheap real session; use a claude-sdk agent for text):**
```
OMNI_AGENT=polly LC_ALL=C nvim --headless --noplugin -u tests/omnigent/minimal_init.lua \
  -c "luafile tests/omnigent/live_smoke.lua" -c "qa!"
```

## Architecture / data flow

```
omnigent/sse.lua      raw SSE text -> decoded events (injectable frame source; no I/O)
omnigent/events.lua   reducer: events -> normalized updates {kind,response_id?,...}
                      (STATEFUL: tracks current_response_id, accumulates assistant text)
omnigent/client.lua   REST + SSE transport (INJECTABLE request/job); fail-closed host
                      resolution; opaque ids; pagination
omnigent/session.lua  per-chat runtime (the acp.Connection analog): create/load,
                      start/stop_stream, post_message/interrupt, set_model, labels
adapters/omnigent/    family factory (init.lua) + generic template (default.lua)
interactions/chat/omnigent/handler.lua  foreground glue: ensure_session -> RequestStarted
                      -> start_stream -> post -> render deltas -> _complete()+detach;
                      plus resume() (load+hydrate, no post)
interactions/chat/omnigent/render.lua   durable item -> chat message mappers (snapshot/resume)
chat/init.lua         dispatch (_submit_omnigent), close (stop_stream), change_model,
                      update_metadata omnigent arms
```
Chat contract mirrors ACP: accumulate assistant chunks in `handler.output`, hand to
`chat:done(output, reasoning)`; `chat:add_buf_message` streams to the buffer.

## Key invariants — DO NOT regress (each caused a reviewer-found bug)

- **IDs are opaque** — never sniff `conv_`/`ag_` prefixes; resolve agent id-first-then-name.
- **Host fail-closed** — `host="auto"` refuses on zero/ambiguous match; `workspace="auto"`
  only sends cwd when the host is this machine; never leak local paths to a remote host.
- **Dedup = content/byte equality** — deltas carry NO ids; anchor the per-turn text
  accumulator on `current_response_id` from `response.created`/`in_progress`.
- **Stream-first reconnect** — in-flight text is replayed on `/stream` subscribe, NOT in
  `/items`. Naive reopen double-renders → `stream_reconnect` is gated `false` until M4.
- **Interrupt = `{"type":"interrupt","data":{}}`** (empty OBJECT); it does not stop/delete
  the session; `session.interrupted` (not `response.cancelled`) ends an interrupted turn.
- **Handler MUST fire `RequestStarted` (before stream/post) + `RequestFinished` (paired)** —
  the user's input queue + spinners depend on them.
- **Handler MUST detach from the session on completion** — otherwise background/wakeup
  events render through a finished handler.
- **Resume = `OmnigentHandler:resume()`** (load + hydrate, no post). NEVER resume through
  `submit()`; a blank/no-unsent submit is a clean no-op (`ready_for_input`), not an error.
- **Hydration uses role-appropriate `MESSAGE_TYPES`** (`USER_MESSAGE` vs `LLM_MESSAGE`).
- **Default to a claude-sdk agent** — `*-native-ui` (terminal) agents stream NO text to CC.
- **Adapter extend** — extend the family `"default"` via the family module
  (`require("codecompanion.adapters.omnigent").extend("default", {...})`); extending
  `"omnigent"` recurses and routing `"default"` through top-level `extend()` misfires to http.
- **omnigent owns tools server-side** — don't push CC's local tool registry (mcp start skipped).

## Open small fix (do first)

Dotfiles `tab_chat_set_adapter`'s `apply()` disconnects an outgoing ACP connection but
does NOT `stop_stream()` an outgoing omnigent session → in-place adapter swap leaks the
SSE stream. Add: `if chat.adapter.type=="omnigent" and chat.omnigent_session then chat.omnigent_session:stop_stream() end`.

## Milestones

- **M1 — Protocol client + adapter type: COMPLETE, verified (unit + live).**
- **M2 — Foreground chat: COMPLETE, verified (unit/integration + live protocol e2e; buffer *rendering* pending manual GUI check).**
- M3 — Resume/list/metadata: layer pieces done (`client:list_sessions`,
  `session:load`, `render.snapshot_messages`, `update_metadata` omnigent arm);
  UI commands (`/resume`, `/session`, `/sessions`) NOT yet wired.
- M4 — Wakeups / passive streaming: NOT started (the marquee feature; the reducer
  already synthesises background turns and the stream stays open on close only via
  `stop_stream`, so the substrate exists).
- M5 — Meta-harness (elicitations, tools, child sessions): NOT started
  (`session:resolve_elicitation` + reducer `elicitation`/`child_session` updates
  exist; no UI).
- M6 — Generic sessionful interface refactor: NOT started.

## Post-review fixes (applied)

A code review flagged defects; addressed:

- **Lifecycle race** — `RequestStarted` now fires BEFORE `start_stream`/`post`;
  post-failure routes through `_complete` so `RequestFinished` always pairs. (test)
- **Background leak** — the handler now DETACHES from the session on completion
  (`_detach`), so post-turn/background stream events never render through a
  finished foreground handler. (test)
- **`load` fail-loud + pagination** — `Session:load` propagates item-fetch errors
  instead of returning `{}`; `Client:list_items` follows pagination. (test)
- **`stream_reconnect`** — was advertised but unimplemented; now `false` +
  documented as M4-reserved (a naive reopen would double-render the stream's
  in-flight replay).
- **Resume hydration** — the load path now hydrates the transcript + buffer from
  durable items (`_hydrate` → `render.snapshot_messages`), marked sent. (test)
- **Elicitation (defensive)** — a foreground turn hitting an elicitation now
  surfaces a visible "resolve in Omnigent UI" note instead of silently hanging;
  full handling is M5.

### Round 2 (resume correctness)

- **Bare resume no longer errors** — a blank/no-unsent submit is now a clean no-op
  (`ready_for_input`), not `status="error"`. (test)
- **`OmnigentHandler:resume()`** added — loads + hydrates history WITHOUT posting a
  turn (the correct M3 entry; `submit()` is only for new turns). (test)
- **Hydration uses role-appropriate buffer types** — user turns render as
  `USER_MESSAGE`, not `LLM_MESSAGE`. (test)
- Test noise: the `[ERROR]` lines under the lean init were intentional error-path
  logs (now silenced). The tree-sitter noise a reviewer saw is from `make test`
  (full init) hitting the missing `tree-sitter` CLI — run omnigent tests via
  `tests/omnigent/minimal_init.lua`, or install the CLI.

Still correctly deferred (milestones, not defects): full M4 wakeups + reconnect
reconcile, full M5 elicitation UI, M3 `/resume` command/picker (engine + `resume()`
now correct — only the UI remains), M6 refactor, and GUI render verification
(tree-sitter gap).

## New files

```
lua/codecompanion/omnigent/client.lua        REST+SSE client; fail-closed host resolution; opaque ids
lua/codecompanion/omnigent/sse.lua           Transport-agnostic SSE parser (injectable frame source)
lua/codecompanion/omnigent/events.lua        Stateful reducer -> normalised updates
lua/codecompanion/omnigent/session.lua       Per-chat session runtime (acp.Connection equivalent)
lua/codecompanion/adapters/omnigent/init.lua     Adapter family factory
lua/codecompanion/adapters/omnigent/default.lua  Generic omnigent adapter template
lua/codecompanion/interactions/chat/omnigent/handler.lua  Foreground turn orchestration
lua/codecompanion/interactions/chat/omnigent/render.lua   Durable-item -> message mappers (snapshot)
```

## Edited files (additive; existing families unaffected — ACP suite still green)

```
lua/codecompanion/adapters/init.lua          adapter_type + resolve/resolved/extend/make_safe/set_model omnigent arms
lua/codecompanion/config.lua                 config.adapters.omnigent = { omnigent = "default", ... }
lua/codecompanion/interactions/chat/keymaps/change_adapter.lua  picker merge + list_omnigent_models + select_model arm
lua/codecompanion/interactions/chat/init.lua _submit_omnigent, submit dispatch, start_mcp skip, change_model,
                                             close (stop_stream), update_metadata omnigent arm
```

## Tests (MiniTest) — 68 cases, 0 fails

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
- With **claude-native-ui** (a terminal harness) the turn completes but emits NO
  `output_text` deltas — its output goes to the tmux terminal, not the SSE text
  stream. => For CodeCompanion to render assistant text, default to a `claude-sdk`
  agent (this is why the claude-sdk posture was chosen). The default agent in
  `default.lua` is still `claude-native-ui` and should be overridden in dotfiles.

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
   agent; open a chat with `adapter=omnigent`; submit a prompt; confirm streamed
   assistant text renders in the buffer.
2. Cancel mid-turn (Ctrl-C) → confirm the turn stops and the session survives
   (resendable).
3. Confirm existing ACP adapters/customisations still work unchanged (regression).
4. `/model` picker lists omnigent models once a session exposes `model_options`.

## Known limitations / next steps

- REST calls in the handler (create/post) are synchronous → the editor briefly
  blocks on first-message session creation, same shape as the pre-existing ACP
  case your dotfiles solved with an `async_utils.sync` wrap. Apply the same wrap
  to `_submit_omnigent` when integrating.
- The dotfiles lib ecosystem (winbar pill, context %, queue, etc.) keys on
  `chat.acp_connection`/`acp_session_id`; omnigent chats set
  `chat.omnigent_session`/`omnigent_session_id`. Those modules need the shared
  session resolver + neutral event re-emit (see the lib migration matrix in the
  groundwork synthesis) before they light up for omnigent — this is M3 UI work.
```
