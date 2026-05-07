# Claude Agent Backend — Design

**Date:** 2026-05-07
**Status:** Approved, ready for implementation plan

## Goal

Add a second agent backend to Symphony that runs Anthropic's Claude via the [Claude Agent SDK](https://docs.anthropic.com/claude/docs/claude-agent-sdk), selectable per-workflow via config, so operators can drive issues with Claude instead of (or alongside) the existing Codex CLI backend.

## Non-Goals (v1)

- Tool approval UI or sandbox policies. The SDK defaults apply; revisit once the feature is proven.
- `WORKFLOW.md` credential plumbing for Anthropic. Reuse `~/.claude/` auth (the same credentials `claude` CLI uses).
- Remote SSH worker support for the Claude backend. The existing SSH path stays Codex-only; Claude runs locally only in v1.
- Retiring or deprecating the Codex backend. Both backends coexist behind a config switch.

## Success Criteria

- Setting `agent.backend: :claude` in a workflow causes a real issue (e.g. HA-1) to produce timeline events (`tool_call`, `tool_result`, `message`, `thinking`, `tokens`, `turn_start`, `turn_end`) visible live at `/issues/:identifier`.
- Default behavior with `agent.backend: :codex` (or unset) is byte-identical to today.
- No new warnings in the Elixir test suite; no regression in existing tests.

---

## Architecture

Three new pieces, one config field, one dispatch site. The existing observability pipeline (`EventNormalizer`, `Timeline`, `IssueDetailLive`) is unchanged — the Claude wrapper emits events in the vocabulary `EventNormalizer` already understands.

### New

1. **`elixir/priv/claude_agent/`** — Node package that wraps the Claude Agent SDK.
   - `package.json` with a single dependency: `@anthropic-ai/claude-agent-sdk`.
   - `index.mjs` (~100 lines) — reads line-delimited JSON from stdin, drives `query()` per `start` message, streams events to stdout as line-delimited JSON, exits on `stop` or EOF.
   - `package-lock.json` committed for reproducible installs.
   - `README.md` — one paragraph on what it is, install instructions (`npm ci`), manual-invocation recipe for debugging.

2. **`elixir/lib/symphony_elixir/claude/app_server.ex`** — Elixir client, analogous to `SymphonyElixir.Codex.AppServer`.
   - Same public API surface: `start_session/2`, `run_turn/4`, `stop_session/1`.
   - Internally: spawns `node priv/claude_agent/index.mjs --workspace <path>` via `Port.open`, manages a newline-buffered read loop, translates wrapper events into the same `on_message` callback shape `AgentRunner` already consumes.
   - Significantly simpler than `Codex.AppServer` (~1,100 lines) because the protocol is purpose-built — no thread-ID juggling, no dynamic tool registration, no approval round-trips. Target: ~300 lines.

3. **`elixir/lib/symphony_elixir/agent_backend.ex`** — tiny dispatcher module.
   - Function `app_server_module/0` returns `SymphonyElixir.Codex.AppServer` or `SymphonyElixir.Claude.AppServer` based on `Config.settings!().agent.backend`.
   - `AgentRunner` replaces its direct `AppServer.start_session(...)` calls with `AgentBackend.app_server_module().start_session(...)`.

### Modified

4. **`elixir/lib/symphony_elixir/config/schema.ex`** — `Agent` schema gains:
   ```elixir
   field(:backend, Ecto.Enum, values: [:codex, :claude], default: :codex)
   ```

5. **`elixir/lib/symphony_elixir/agent_runner.ex`** — replace three direct module references to `AppServer` (inside `run_codex_turns/6` and `do_run_codex_turns/8`) with dispatched calls via `AgentBackend.app_server_module()`. ~6 lines changed.

### Not Modified

- `orchestrator.ex` — still receives `{:codex_worker_update, issue_id, %{event: ..., timestamp: ...}}` messages. The message tag stays `:codex_worker_update` to limit blast radius; it now means "agent update" regardless of backend. Rename is deferred to a separate PR.
- `event_normalizer.ex` — already handles the event shapes the Node wrapper will emit.
- `timeline.ex`, `observability_pubsub.ex`, `issue_detail_live.ex`, dashboard — unchanged.

### Data Flow (per turn)

```
AgentRunner.run_codex_turns
  → AgentBackend.app_server_module() = Claude.AppServer
  → Claude.AppServer.start_session(workspace)
     → Port.open("node priv/claude_agent/index.mjs --workspace <path>")
     → (wrapper emits {"event":"ready"})
  → Claude.AppServer.run_turn(session, prompt, issue, opts)
     → send stdin: {"type":"start","prompt":...,"session_id":<optional>}
     → read stdout line by line:
         {"event":"turn_start"} → on_message(:turn_started, ...)
         {"event":"tool_call"}  → on_message(:tool_call_started, ...)  → orchestrator timeline
         {"event":"tool_result"}→ on_message(:tool_call_completed, ...) → orchestrator timeline
         {"event":"message"}    → on_message(:agent_message, ...)       → orchestrator timeline
         {"event":"thinking"}   → on_message(:agent_reasoning, ...)     → orchestrator timeline
         {"event":"tokens"}     → on_message(:usage, ...)               → orchestrator tokens + timeline
         {"event":"turn_end"}   → loop exits, returns {:ok, %{session_id, ...}}
  → (repeat run_turn for subsequent turns, passing session_id back)
  → Claude.AppServer.stop_session(session)
     → send stdin: {"type":"stop"}
     → wait for port close, return :ok
```

The wrapper's event vocabulary maps 1:1 onto what `EventNormalizer` already normalizes. This is deliberate: the matching vocabulary reduces the integration work to a protocol adapter.

---

## Wrapper Protocol

### Invocation

```
node priv/claude_agent/index.mjs --workspace /path/to/workspace
```

Workspace is passed as a CLI arg so the wrapper sets its own `cwd` and hands it to the SDK.

### Stdin (Symphony → wrapper)

Line-delimited JSON.

```json
{"type":"start","prompt":"...","session_id":"sess_abc...","max_turns":1}
```
- `prompt` — the turn prompt Symphony built (includes issue title, description, operator instructions).
- `session_id` — optional. Omit on first turn; pass the value the wrapper emitted in the previous `turn_end` so the SDK resumes conversation history across Symphony turns.
- `max_turns` — always `1` from Symphony's side. The SDK's internal reasoning loop is unbounded within one turn; Symphony's `agent_runner.ex` owns the multi-turn loop.

```json
{"type":"stop"}
```
Graceful shutdown. Wrapper closes the SDK handle, flushes remaining events, exits 0.

### Stdout (wrapper → Symphony)

Line-delimited JSON.

```json
{"event":"ready","timestamp":"2026-05-07T20:00:00Z"}
```
Emitted once on startup after the SDK is loaded. `start_session/2` waits for this line before returning `{:ok, session}`.

Per-turn events:
```json
{"event":"turn_start","turn":1,"timestamp":"..."}
{"event":"thinking","text":"...","timestamp":"..."}
{"event":"tool_call","tool":"Read","args":{"path":"lib/foo.ex"},"tool_call_id":"tc_abc","timestamp":"..."}
{"event":"tool_result","tool":"Read","ok":true,"exit":null,"output":"<possibly truncated>","tool_call_id":"tc_abc","timestamp":"..."}
{"event":"message","text":"Here's what I found...","timestamp":"..."}
{"event":"tokens","input":1234,"output":567,"total":1801,"timestamp":"..."}
{"event":"turn_end","turn":1,"session_id":"sess_abc...","timestamp":"..."}
```

- `turn` starts at `1` per SDK `query()` call (not per Symphony session). Symphony's orchestrator tracks its own turn number on top.
- `tool_call_id` ties calls to results. Not required by v1 timeline rendering but cheap to include for future use.
- `output` is truncated to 8KB in the wrapper before emission. `EventNormalizer` further truncates summary to 200 chars.
- `session_id` on `turn_end` is what Symphony echoes back on the next `start` to resume the conversation.
- `tokens` is emitted once at `turn_end` with cumulative totals for that turn.

Session termination:
```json
{"event":"session_end","reason":"completed","detail":null,"timestamp":"..."}
{"event":"session_end","reason":"error","detail":"<error message>","timestamp":"..."}
```
Emitted before the wrapper exits. `reason: "completed"` on `stop` / EOF; `reason: "error"` on unhandled SDK exception (auth failure, network error, etc.).

### Stderr

Node's own logs (startup, uncaught errors). `Claude.AppServer` reads stderr separately from stdout (unlike Codex's `:stderr_to_stdout` flag) and routes it through `Logger.debug`. Stderr never contributes to timeline events.

---

## Error Handling

- **Missing `node` runtime.** `System.find_executable("node")` in `Claude.AppServer.start_session/2` returns `{:error, :node_not_found}`. Propagates up to `AgentRunner.run/3`, which already logs `"Agent run failed..."`. Symmetric to Codex's `:bash_not_found`.
- **Missing wrapper dependencies (`node_modules/` not installed).** Node errors out on first `import`. Startup-failure path (no `ready` event within ~10 seconds) returns `{:error, {:wrapper_startup_failed, exit_code, stderr_tail}}`. The stderr tail makes the missing-module error legible to the user.
- **Missing Claude auth (`~/.claude/` empty or invalid).** The SDK throws on first API call. Wrapper emits `{"event":"session_end","reason":"error","detail":"<auth error>"}` and exits. Symphony marks the turn failed; existing retry logic handles it.
- **Backend mismatch with SSH worker.** `Claude.AppServer.start_session/2` returns `{:error, {:unsupported_worker_host, host}}` when `worker_host` is non-nil. Explicit v1 limitation, documented in the error.
- **Unparseable stdout line from wrapper.** Log a warning with the offending line, skip it, keep reading. Never crash the Port.
- **Config validation.** `Ecto.Enum` rejects values other than `:codex` / `:claude` at config load time with a clear error.
- **Stall detection.** Existing `agent_runner.ex` watchdog fires after 5 minutes without activity, same as Codex backend.

---

## Testing

1. **Wrapper unit tests (Node, not in Elixir suite).** `priv/claude_agent/index.test.mjs` with a fake SDK (`query()` returns a mock async iterator). Covers: stdin parsing, event emission order, `ready` timing, graceful `stop`. Runs via `npm test` in `priv/claude_agent/`. Wired into `Makefile` as `make test-claude-wrapper`.

2. **Elixir unit tests for `Claude.AppServer`.** `test/symphony_elixir/claude/app_server_test.exs`. Uses a fake Node-equivalent (shell script or tiny Elixir escript) that reads stdin and writes canned event sequences. Covers:
   - `start_session/2` returns `{:ok, session}` after `ready`.
   - `start_session/2` returns `{:error, ...}` on startup failure (wrapper exits before `ready`).
   - `run_turn/4` streams events through `on_message` in order.
   - Token totals are surfaced correctly.
   - `stop_session/1` cleans up the Port.

3. **`AgentBackend` dispatcher test.** Trivial — one test per backend value, asserts correct module is returned.

4. **Integration test (gated, skipped by default).** `test/symphony_elixir/claude/live_test.exs` tagged `@tag :claude_live`. Requires real Claude auth and `priv/claude_agent/node_modules/` installed. Runs one actual turn against a throwaway workspace. Gated behind `CLAUDE_LIVE_E2E=1` env var (matches the existing `SYMPHONY_RUN_LIVE_E2E` pattern for Codex).

5. **No new tests for `EventNormalizer`, `Timeline`, `IssueDetailLive`.** These are backend-agnostic and already covered.

---

## Migration / Rollout

- PR introduces all three new modules + config field with default `:codex`. **Zero behavior change for existing users on merge.**
- Opt-in:
  1. Set `agent.backend: :claude` in the workflow file.
  2. `cd elixir/priv/claude_agent && npm ci` once.
  3. Ensure `claude` CLI is logged in (`claude login` or existing session in `~/.claude/`).
- If Claude proves stable over several real runs, flip the default to `:claude` in a one-line follow-up PR.
- Rollback: set `backend: :codex` in config, or revert the config-default change. All Claude code is opt-in; the Codex path is never touched by this work.

---

## Explicitly Deferred

Listed to prevent scope creep during implementation:

- Tool approval UI.
- Remote SSH worker support for Claude backend.
- MCP server support inside the wrapper.
- Renaming `:codex_worker_update` to a backend-agnostic tag — mechanical refactor, separate PR.
- Per-issue backend selection (workflow-level is the only granularity in v1).
- Claude-specific settings (model, max_tokens, temperature). SDK defaults for v1; add config fields when a real need surfaces.
