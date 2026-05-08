# Debug Logging & `--debug` Flag Design

Date: 2026-05-08
Status: Draft

## Problem

Debugging stuck or failing Symphony runs is slower than it needs to be:

- The Claude backend (`SymphonyElixir.Claude.AppServer`) emits only a single
  `Logger.warning` for unparseable wrapper lines. Everything else — session
  start, turn lifecycle, turn errors, wrapper subprocess details — is silent.
  A concrete case: an `HA-1` run that sat at "Starting worker attempt" for
  minutes produced no session-level log lines at all.
- `AgentRunner` does not record which backend was selected, making it unclear
  which code path is running for a given issue.
- There is no quick way to increase log verbosity at runtime. Developers have
  no dial between "normal info logs" and "tell me everything".

## Goals

1. Add a `--debug` CLI flag that raises log verbosity globally at startup.
2. Close the highest-value logging gaps on the Claude path and around backend
   selection, following the conventions in `elixir/docs/logging.md`.

## Non-Goals

- No dashboard/TUI changes.
- No env-var toggle (`SYMPHONY_DEBUG`, etc.). CLI flag only.
- No per-module or dynamic log-level control at runtime.
- No structured/JSON log formatter change — stay with current plain-text format.
- No changes to Codex.AppServer logs beyond the shared `start_session`
  signature (see below).

## Design

### `--debug` flag

`SymphonyElixir.CLI` parses a new boolean `--debug` flag. When present, before
starting the supervisor:

1. `Logger.configure(level: :debug)`.
2. `Application.put_env(:symphony_elixir, :debug_mode, true)`.

Absent, log level and app env are untouched.

The `:debug_mode` app env exists so a small number of call sites can avoid
high-volume debug logging even when level is `:debug` — specifically the raw
wrapper-line dump in `Claude.AppServer.handle_line/3`. Everything else uses
plain `Logger.debug/1` and is naturally gated by the log level.

### Log gap fills

All log lines follow `elixir/docs/logging.md`: include `issue_id`,
`issue_identifier` when tied to an issue, and `session_id` when tied to a
Claude session.

#### 1. `Claude.AppServer` lifecycle logs

Add the following `Logger.info` calls mirroring `Codex.AppServer`:

- `start_session` success:
  `Claude session started issue_id=... issue_identifier=... workspace=...`
- `start_session` failure:
  `Claude session failed to start issue_id=... issue_identifier=... reason=...`
- `run_turn` entry:
  `Claude turn starting issue_id=... issue_identifier=... session_id=...`
- `run_turn` success:
  `Claude session completed issue_id=... issue_identifier=... session_id=... tokens_in=... tokens_out=...`
- `run_turn` terminal error paths (`:turn_timeout`, `{:wrapper_exited, code}`,
  `{:session_ended, reason, detail}`):
  `Claude session ended with error issue_id=... issue_identifier=... session_id=... reason=... detail=...`
- `stop_session`:
  `Claude session stopped issue_id=... issue_identifier=... session_id=...`

#### 2. Wrapper event bridge (debug-gated)

Inside `Claude.AppServer.handle_line/3`, when `:debug_mode` app env is true,
log each decoded event:

`Logger.debug("Claude wrapper event=#{event} session_id=... raw=<first 200 chars of line>")`

Add `:stderr_to_stdout` to the `Port.open` opts so wrapper stderr flows
through the same event loop. When a line fails JSON decode, log it as
`Logger.debug("Claude wrapper stderr: #{line}")`. Keep the existing
`Logger.warning` for unparseable lines only when `:debug_mode` is false
(otherwise the debug line is enough).

#### 3. Subprocess spawn details

In `Claude.AppServer.open_port/4`, immediately before `Port.open`:

`Logger.info("Spawning Claude wrapper executable=#{executable} args=#{inspect(args)} cwd=#{workspace} env_keys=#{inspect(Enum.map(env, &elem(&1, 0)))}")`

Env *keys* only — never values — to avoid leaking secrets.

#### 4. `AgentRunner` decision points

In `run_codex_turns/5`:

- Info, immediately after `app_server = AgentBackend.app_server_module()`:
  `Agent backend selected backend=<:codex|:claude> module=<module> issue_id=... issue_identifier=...`
- Info, after successful `start_session`:
  `AppServer.start_session succeeded for issue_id=... issue_identifier=... backend=...`
- Debug, inside `do_run_codex_turns/7`, per turn:
  `Starting turn issue_id=... issue_identifier=... turn=<n>/<max>`

Existing failure log on `start_session` stays.

### Interface changes

Only one signature change.

`SymphonyElixir.Claude.AppServer.start_session/2` accepts new opts:

- `:issue_id` (String.t() | nil)
- `:issue_identifier` (String.t() | nil)

The returned session map stores them:

```elixir
%{
  port: port(),
  buffer: String.t(),
  workspace: Path.t(),
  session_id: String.t() | nil,
  worker_host: nil,
  issue_id: String.t() | nil,
  issue_identifier: String.t() | nil
}
```

`run_turn/4` and `stop_session/1` read these from the session to build log
context; their public signatures do not change.

`SymphonyElixir.Codex.AppServer.start_session/2` accepts the same two opts
for interface symmetry but may ignore them (Codex already plumbs issue
context separately).

`SymphonyElixir.AgentRunner` (at `run_codex_turns/5`) forwards the context:

```elixir
app_server.start_session(workspace,
  worker_host: worker_host,
  issue_id: issue.id,
  issue_identifier: issue.identifier
)
```

### Error handling & edge cases

- `Logger.configure(level: :debug)` is idempotent; safe if level is already
  `:debug`.
- `--debug` takes no value. Any trailing token is handled by the existing
  arg parser (no change).
- Subprocess spawn log prints env *keys* only.
- If `AgentRunner` does not pass `:issue_id`/`:issue_identifier` (e.g., test
  paths), session fields are `nil` and log lines render `issue_id=`. This
  matches how existing Codex.AppServer logs tolerate missing context.
- `:stderr_to_stdout` merges the wrapper's stderr into stdout lines. Non-JSON
  lines are routed to `Logger.debug` so they stay silent under normal info
  level.
- The `:session_end` handler already returns an error tuple; add a
  `Logger.warning` with session context before returning.

## Testing

- `cli_test.exs` (or the appropriate CLI test module): `--debug` sets
  `Logger.level()` to `:debug` and `:debug_mode` app env to `true`. Without
  the flag, both are unchanged.
- `claude/app_server_test.exs`: `start_session` stores `:issue_id` and
  `:issue_identifier` on the session map. `ExUnit.CaptureLog` asserts the
  info-level lifecycle lines appear with the expected keys on a successful
  turn through the fake SDK.
- `agent_runner_test.exs` (if coverage exists): verify issue context is
  forwarded to `start_session`.

Not tested:

- Debug-gated raw-line dump and wrapper stderr capture (environment-dependent;
  manual verification via `--debug` on a real run).
- Subprocess spawn log (manual verification).

## Out-of-Scope Follow-ups

- Env-var toggle and dynamic level control.
- Dashboard debug panel / live log tail.
- Structured log format (JSON) and correlation IDs across subsystems.
