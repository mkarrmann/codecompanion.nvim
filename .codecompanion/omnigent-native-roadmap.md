# Omnigent Native — Remaining Work Scope

Companion to `omnigent-native-progress.md` (what's done: M1 + M2, live-validated;
74 unit cases). This scopes everything left.

**Legend** — Effort: **S** localized edit / one function · **M** new module or
multi-file · **L** new subsystem. Where: **[P]** plugin (codecompanion.nvim) ·
**[D]** dotfiles. Verify: **unit** (headless MiniTest) · **live** (real server) ·
**GUI** (manual, blocked here by the missing tree-sitter CLI).

---

## 0. Fixes & cleanups (pre-milestone)

| Task | Where | Effort | Verify |
|---|---|---|---|
| In-place adapter-swap leak: `apply()` must `stop_stream()` an outgoing omnigent session (symmetric to the ACP disconnect) | [D] | S | GUI |
| Run `stylua` on new files (not installed here; hand-matched style) | [P] | S | — |
| (Optional) async REST client via `vim.system` — NOT needed (create/post return <1s) | [P] | M | unit |

---

## C. Lib-ecosystem parity (dotfiles) — make omnigent chats feel native

The chat *works* today, but the winbar pill / context-% / stats are blank because
they key on `chat.acp_connection`. This lights them up.

| Task | Where | Effort | Verify |
|---|---|---|---|
| New `lib/codecompanion-session.lua`: `session_id(chat)` returning acp OR omnigent id | [D] | S | unit |
| `overrides.lua` winbar `cc_session_id` → shared resolver | [D] | S | GUI |
| `codecompanion-chatinfo`: `pin()` on the `OmnigentSessionReady` autocmd (already fired) | [D] | S | GUI |
| Fire a neutral usage event (`CodeCompanionOmnigentUsage {bufnr,usage}`) from the handler's `usage` update | [P] | S | unit |
| `codecompanion-stats`: consume omnigent usage; derive context-% from model context_window | [D] | M | GUI |
| `codecompanion-statusline` + `codecompanion-reap` + `codecompanion-doctor`: omnigent arms | [D] | S each | GUI |

**Rollup: ~M.** Mostly small. Gotcha: `session.usage` often has null
`context_tokens`/`context_window` with claude-sdk — the populated numbers are on
`response.completed.usage` (`context_tokens`), so stats may need to read from turn
completion, not just `session.usage`. `timing`/`tool-output`/`queue`/`autocmds`
are already transport-neutral (no change).

---

## M3. Resume / list / metadata

**Done:** `client:list_sessions`, `session:load` + `_hydrate`, `snapshot_messages`,
`update_metadata` (model), and a correct **`OmnigentHandler:resume()`** entry that
loads + hydrates history WITHOUT posting (bare resume no longer errors; user turns
render with `USER_MESSAGE`). What remains is the UI that *calls* `resume()`.

| Task | Where | Effort | Verify |
|---|---|---|---|
| Fill `update_metadata` omnigent fields: host, workspace, status, effort, pending_elicitations | [P] | S | unit |
| `/session` (show current session metadata) | [P] | S | GUI |
| `/sessions` picker over `list_sessions` → open with `omnigent_session_id` | [P] | M | GUI |
| dotfiles resume UX: fork `acp-broker-sessions.lua` → `lib/omnigent-sessions.lua` (parse list, cwd/agent/label filter) + a `broker_continue`-style picker + `_open_chat_with_session` analog | [D] | M–L | GUI |
| `/children` (overlaps M5 child surfacing) | [P] | S | GUI |

**Rollup: ~M–L.** Layer is done; the pickers/commands + dotfiles resume UX are the
work. Mirrors your existing broker resume/fork/continue closely.

---

## M4. Wakeups / passive streaming — the marquee (why native)

**Substrate present:** reducer synthesizes background turns for id-less deltas with
no open turn; foreground handler detaches on completion; the stream survives after
a turn.

| Task | Where | Effort | Verify |
|---|---|---|---|
| Persistent **session observer**: open stream at chat-attach (not just first submit); bound to `on_update`, renders background turns while no foreground request is active | [P] | L | unit+GUI |
| Background-turn rendering with distinct styling ("User (external)" / "System wakeup:") | [P] | M | GUI |
| Foreground/background arbitration (foreground handler wins during an active turn; observer resumes after) | [P] | M | unit |
| Dedupe background turns vs `/items` (content-based, stream-first ordering) | [P] | M | unit |
| Fire `ChatOmnigentWakeup` / `ChatOmnigentBackgroundTurn` autocmds | [P] | S | unit |
| Reconnect + reconcile: implement `stream_reconnect` — reopen on drop/heartbeat-timeout + refetch `/items` + reconcile (the reason it's gated off today) | [P] | L | unit+live |
| Heartbeat-timeout timer (`stream_heartbeat_timeout`) | [P] | S | unit |
| **Scriptable fake-server harness** for background + reconnect scenarios (M2 tests use fake-client transport; this needs scripted event injection + drop/replay) | [P] | M | — |
| Wire wakeup autocmds → notifications | [D] | S | GUI |

**Rollup: ~L (largest).** Decision needed (open q #4): keep the stream open for
hidden buffers, visible-only, or all attached sessions (presence + a runner
subscription per buffer). Reconnect+reconcile is the hard part; the scriptable
harness is the verification vehicle.

---

## M5. Meta-harness richness

**Substrate present:** reducer emits `elicitation` / `child_session` / `other`;
`session:resolve_elicitation`; a defensive "resolve in Omnigent UI" note.

| Task | Where | Effort | Verify |
|---|---|---|---|
| **Elicitations** (highest value): map `response.elicitation_request` (MCP-shaped params) → reuse ACP `request_permission`/form UI; block; resolve via `session:resolve_elicitation`; render `elicitation_resolved` | [P] | M | GUI |
| `codecompanion-elicitation.lua`: add omnigent binding (extract MCP render core behind `run_elicitation_form`) | [D] | M | GUI |
| Tool/native rendering: `function_call`/`function_call_output` items → tool cards (mirror acp formatters) + `codecompanion-tool-output` feed | [P] | M | GUI |
| Child sessions: surface `session.child_session.updated` (status line / foldable rows) + `/children` | [P] | M | GUI |
| Inbox/task/timer meta + `policy_denied` rendering | [P] | S–M | GUI |

**Rollup: ~L.** Independent pieces; do elicitations first (security posture — CC as
the approval authority is only real for claude-sdk agents).

---

## M6. Generic sessionful-adapter interface

| Task | Where | Effort | Verify |
|---|---|---|---|
| Extract `interactions.chat.session` interface (ensure/submit/cancel/list/load/set_model/set_config/close) | [P] | M | unit |
| Migrate omnigent onto it (low risk) | [P] | M | unit |
| Reduce `adapter.type` branching (chat/init.lua, change_adapter) | [P] | M | unit |
| (Optional, risky) migrate ACP onto it — your ~10 ACP monkeypatches make this high-risk; recommend a separate workstream | [P] | L | GUI |

**Rollup: ~M–L.** Code-health, low user-facing value. Worth doing **before** adding
a 4th sessionful protocol; recommend omnigent-only extraction first, ACP later.

---

## Cross-cutting

- **GUI verification stays manual** until a `tree-sitter` CLI is installed (unlocks
  the repo's screenshot-golden render tests). Consider installing it — it would let
  M4/M5 render work be tested headlessly instead of by eye.
- Every milestone grows the fixture corpus + fake-server harness (esp. M4).

## Recommended sequence

1. **0 + C** — leak fix + lib parity → daily use feels native. (~M)
2. **M3** — resume; high everyday value, layer already done. (~M–L)
3. **M4** — wakeups; the strategic reason for native. (~L)
4. **M5** — elicitations first, then tools/children. (~L)
5. **M6** — refactor before any further protocol. (~M–L)

Near-term high-value = **C + M3**. The big lift = **M4**. Broadest surface = **M5**.
