# Debug Logging & `--debug` Flag Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `--debug` CLI flag that raises log verbosity globally, and close the highest-value logging gaps on the Claude backend path so stuck runs can be diagnosed from `log/symphony.log` alone.

**Architecture:** Small, additive changes in four files: the CLI parses one new boolean flag and, when set, raises `Logger.level` and flips a `:debug_mode` app env. `SymphonyElixir.Claude.AppServer` gains six info-level lifecycle log lines (mirroring Codex.AppServer), a debug-gated raw-event dump, an info-level spawn log, and an `:issue_id`/`:issue_identifier` pair on the session map. `SymphonyElixir.AgentRunner` forwards issue context to `start_session` and logs backend selection. All log lines follow `elixir/docs/logging.md` conventions.

**Tech Stack:** Elixir, Logger, ExUnit, ExUnit.CaptureLog, existing OptionParser-based CLI.

**Spec:** `docs/superpowers/specs/2026-05-08-debug-logging-design.md`

---

## File Structure

**Create:** none.

**Modify:**

- `elixir/lib/symphony_elixir/cli.ex` — add `--debug` switch, raise Logger level + set `:debug_mode` app env when set.
- `elixir/lib/symphony_elixir/claude/app_server.ex` — add issue context on session map; add lifecycle / spawn / debug-gated event logs; merge stderr into the event stream.
- `elixir/lib/symphony_elixir/agent_runner.ex` — log backend selection and start_session success; forward issue context to `start_session`.
- `elixir/test/symphony_elixir/cli_test.exs` — test `--debug` behavior.
- `elixir/test/symphony_elixir/claude/app_server_test.exs` — test issue context on session map and lifecycle log emission.

---

### Task 1: CLI `--debug` flag

**Files:**
- Modify: `elixir/lib/symphony_elixir/cli.ex`
- Test: `elixir/test/symphony_elixir/cli_test.exs`

- [ ] **Step 1: Add failing test for `--debug` behavior**

Append to `elixir/test/symphony_elixir/cli_test.exs` inside the existing
`defmodule SymphonyElixir.CLITest` (before the final `end`):

```elixir
  test "--debug sets Logger level to :debug and :debug_mode app env to true" do
    previous_level = Logger.level()
    previous_debug_mode = Application.get_env(:symphony_elixir, :debug_mode)

    on_exit(fn ->
      Logger.configure(level: previous_level)

      case previous_debug_mode do
        nil -> Application.delete_env(:symphony_elixir, :debug_mode)
        value -> Application.put_env(:symphony_elixir, :debug_mode, value)
      end
    end)

    # Start from a known-off state
    Logger.configure(level: :info)
    Application.delete_env(:symphony_elixir, :debug_mode)

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "--debug", "WORKFLOW.md"], deps)
    assert Logger.level() == :debug
    assert Application.get_env(:symphony_elixir, :debug_mode) == true
  end

  test "without --debug, Logger level and :debug_mode app env are unchanged" do
    previous_level = Logger.level()
    previous_debug_mode = Application.get_env(:symphony_elixir, :debug_mode)

    on_exit(fn ->
      Logger.configure(level: previous_level)

      case previous_debug_mode do
        nil -> Application.delete_env(:symphony_elixir, :debug_mode)
        value -> Application.put_env(:symphony_elixir, :debug_mode, value)
      end
    end)

    Logger.configure(level: :info)
    Application.delete_env(:symphony_elixir, :debug_mode)

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert Logger.level() == :info
    assert Application.get_env(:symphony_elixir, :debug_mode) in [nil, false]
  end
```

Also add `require Logger` near the top of the test module if not present:

```elixir
  require Logger
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd elixir && mix test test/symphony_elixir/cli_test.exs`
Expected: 2 new tests fail because `--debug` is not a recognized switch — `CLI.evaluate` returns `{:error, usage_message}` instead of `:ok`.

- [ ] **Step 3: Add `--debug` switch and apply it in `evaluate/2`**

In `elixir/lib/symphony_elixir/cli.ex`:

Replace the `@switches` attribute:

```elixir
  @switches [
    {@acknowledgement_switch, :boolean},
    logs_root: :string,
    port: :integer,
    debug: :boolean
  ]
```

Add `require Logger` at the top of the module (after `alias SymphonyElixir.LogFile`):

```elixir
  require Logger
```

Update both `evaluate/2` match arms to apply debug mode before `run/2`:

```elixir
  @spec evaluate([String.t()], deps()) :: :ok | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps),
             :ok <- maybe_enable_debug_mode(opts) do
          run(Path.expand("WORKFLOW.md"), deps)
        end

      {opts, [workflow_path], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps),
             :ok <- maybe_enable_debug_mode(opts) do
          run(workflow_path, deps)
        end

      _ ->
        {:error, usage_message()}
    end
  end
```

Add a private helper (place it near `maybe_set_server_port`):

```elixir
  defp maybe_enable_debug_mode(opts) do
    if Keyword.get(opts, :debug, false) do
      Logger.configure(level: :debug)
      Application.put_env(:symphony_elixir, :debug_mode, true)
    end

    :ok
  end
```

Update `usage_message/0`:

```elixir
  defp usage_message do
    "Usage: symphony [--debug] [--logs-root <path>] [--port <port>] [path-to-WORKFLOW.md]"
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd elixir && mix test test/symphony_elixir/cli_test.exs`
Expected: all CLI tests pass (the new two plus the existing seven).

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/cli.ex elixir/test/symphony_elixir/cli_test.exs
git commit -m "feat(cli): add --debug flag to raise Logger level"
```

---

### Task 2: Plumb issue context into Claude.AppServer session map

**Files:**
- Modify: `elixir/lib/symphony_elixir/claude/app_server.ex`
- Test: `elixir/test/symphony_elixir/claude/app_server_test.exs`

- [ ] **Step 1: Add failing test for issue context on session map**

Append to the `describe "start_session/2"` block in
`elixir/test/symphony_elixir/claude/app_server_test.exs`:

```elixir
    test "stores :issue_id and :issue_identifier on the session map when provided" do
      assert {:ok, session} =
               AppServer.start_session(
                 System.tmp_dir!(),
                 Keyword.merge(opts(), issue_id: "HA-42", issue_identifier: "HA-42")
               )

      assert session.issue_id == "HA-42"
      assert session.issue_identifier == "HA-42"

      :ok = AppServer.stop_session(session)
    end

    test "defaults :issue_id and :issue_identifier to nil when not provided" do
      assert {:ok, session} = AppServer.start_session(System.tmp_dir!(), opts())
      assert session.issue_id == nil
      assert session.issue_identifier == nil

      :ok = AppServer.stop_session(session)
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd elixir && mix test test/symphony_elixir/claude/app_server_test.exs`
Expected: the two new tests fail because the session map does not have
`:issue_id` / `:issue_identifier` keys (`KeyError` on `session.issue_id`).

- [ ] **Step 3: Store issue context on session map**

In `elixir/lib/symphony_elixir/claude/app_server.ex`, update the `@type` block
and `start_session/2`:

```elixir
  @type session :: %{
          port: port(),
          buffer: String.t(),
          workspace: Path.t(),
          session_id: String.t() | nil,
          worker_host: nil,
          issue_id: String.t() | nil,
          issue_identifier: String.t() | nil
        }
```

```elixir
  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) when is_binary(workspace) do
    worker_host = Keyword.get(opts, :worker_host)
    issue_id = Keyword.get(opts, :issue_id)
    issue_identifier = Keyword.get(opts, :issue_identifier)

    if is_nil(worker_host) do
      with {:ok, executable, args, env} <- resolve_launch(workspace, opts),
           {:ok, port} <- open_port(executable, args, workspace, env),
           {:ok, buffer} <-
             await_ready(port, Keyword.get(opts, :ready_timeout_ms, @default_ready_timeout_ms)) do
        {:ok,
         %{
           port: port,
           buffer: buffer,
           workspace: workspace,
           session_id: nil,
           worker_host: nil,
           issue_id: issue_id,
           issue_identifier: issue_identifier
         }}
      end
    else
      {:error, {:unsupported_worker_host, worker_host}}
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd elixir && mix test test/symphony_elixir/claude/app_server_test.exs`
Expected: all tests pass (new and existing).

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/claude/app_server.ex elixir/test/symphony_elixir/claude/app_server_test.exs
git commit -m "feat(claude): store issue context on AppServer session map"
```

---

### Task 3: Claude.AppServer lifecycle info logs

**Files:**
- Modify: `elixir/lib/symphony_elixir/claude/app_server.ex`
- Test: `elixir/test/symphony_elixir/claude/app_server_test.exs`

- [ ] **Step 1: Add failing test asserting lifecycle log lines appear**

Append a new `describe` block to
`elixir/test/symphony_elixir/claude/app_server_test.exs`:

```elixir
  describe "lifecycle logging" do
    import ExUnit.CaptureLog

    test "emits info-level start/turn/completed logs with issue and session context" do
      Logger.configure(level: :info)

      issue = %{id: "HA-99", identifier: "HA-99", title: "fake"}
      start_opts = Keyword.merge(opts(), issue_id: issue.id, issue_identifier: issue.identifier)

      log =
        capture_log(fn ->
          {:ok, session} = AppServer.start_session(System.tmp_dir!(), start_opts)
          {:ok, _summary} = AppServer.run_turn(session, "hello", issue, on_message: fn _ -> :ok end)
          :ok = AppServer.stop_session(session)
        end)

      assert log =~ "Claude session started"
      assert log =~ "issue_id=HA-99"
      assert log =~ "issue_identifier=HA-99"
      assert log =~ "Claude turn starting"
      assert log =~ "Claude session completed"
      assert log =~ "session_id=sess_fake_1"
      assert log =~ "Claude session stopped"
    end

    test "logs start_session failure with reason" do
      Logger.configure(level: :info)

      log =
        capture_log(fn ->
          assert {:error, {:wrapper_startup_failed, _, _}} =
                   AppServer.start_session(
                     System.tmp_dir!(),
                     opts(%{"FAKE_WRAPPER_MODE" => "startup_fail"})
                   )
        end)

      assert log =~ "Claude session failed to start"
      assert log =~ "reason="
    end
  end
```

Also ensure `require Logger` is present at the top of the test module.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd elixir && mix test test/symphony_elixir/claude/app_server_test.exs`
Expected: new lifecycle tests fail — no log lines matching "Claude session started" etc.

- [ ] **Step 3: Add lifecycle logs to Claude.AppServer**

In `elixir/lib/symphony_elixir/claude/app_server.ex`, update `start_session`,
`run_turn`, and `stop_session` to emit the lifecycle logs. Replace the bodies
as follows.

Helper (add near the bottom of the module, above the final `end`):

```elixir
  defp log_context(%{issue_id: issue_id, issue_identifier: issue_identifier, session_id: session_id}) do
    "issue_id=#{issue_id} issue_identifier=#{issue_identifier} session_id=#{session_id}"
  end

  defp log_context(_), do: "issue_id= issue_identifier= session_id="
```

Modify `start_session/2` to log success/failure (replace the existing
function body):

```elixir
  def start_session(workspace, opts \\ []) when is_binary(workspace) do
    worker_host = Keyword.get(opts, :worker_host)
    issue_id = Keyword.get(opts, :issue_id)
    issue_identifier = Keyword.get(opts, :issue_identifier)

    if is_nil(worker_host) do
      with {:ok, executable, args, env} <- resolve_launch(workspace, opts),
           {:ok, port} <- open_port(executable, args, workspace, env),
           {:ok, buffer} <-
             await_ready(port, Keyword.get(opts, :ready_timeout_ms, @default_ready_timeout_ms)) do
        session = %{
          port: port,
          buffer: buffer,
          workspace: workspace,
          session_id: nil,
          worker_host: nil,
          issue_id: issue_id,
          issue_identifier: issue_identifier
        }

        Logger.info(
          "Claude session started issue_id=#{issue_id} issue_identifier=#{issue_identifier} workspace=#{workspace}"
        )

        {:ok, session}
      else
        {:error, reason} = err ->
          Logger.error(
            "Claude session failed to start issue_id=#{issue_id} issue_identifier=#{issue_identifier} reason=#{inspect(reason)}"
          )

          err
      end
    else
      {:error, {:unsupported_worker_host, worker_host}}
    end
  end
```

Modify `run_turn/4`:

```elixir
  @spec run_turn(session(), String.t(), map(), keyword()) ::
          {:ok, %{session_id: String.t() | nil}} | {:error, term()}
  def run_turn(%{port: port} = session, prompt, _issue, opts) when is_binary(prompt) do
    on_message = Keyword.get(opts, :on_message, fn _ -> :ok end)

    Logger.info("Claude turn starting #{log_context(session)}")

    cmd = %{type: "start", prompt: prompt, max_turns: 1}

    cmd =
      case session.session_id do
        nil -> cmd
        sid -> Map.put(cmd, :session_id, sid)
      end

    send_command(port, cmd)

    case read_until_turn_end(port, session.buffer, on_message) do
      {:ok, %{session_id: sid} = summary} ->
        updated_session = %{session | session_id: sid}

        Logger.info(
          "Claude session completed #{log_context(updated_session)} tokens_in=#{Map.get(summary, :tokens_in, 0)} tokens_out=#{Map.get(summary, :tokens_out, 0)}"
        )

        {:ok, summary}

      {:error, reason} = err ->
        Logger.warning(
          "Claude session ended with error #{log_context(session)} reason=#{inspect(reason)}"
        )

        err
    end
  end
```

Modify `stop_session/1` to add a log line (keep the existing `is_port` and
fallback clauses):

```elixir
  @spec stop_session(session() | %{port: port()}) :: :ok
  def stop_session(%{port: port} = session) when is_port(port) do
    Logger.info("Claude session stopped #{log_context(session)}")

    send_command(port, %{type: "stop"})

    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      2_000 ->
        Port.close(port)
        :ok
    end
  end

  def stop_session(%{port: port}) when is_port(port) do
    send_command(port, %{type: "stop"})

    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      2_000 ->
        Port.close(port)
        :ok
    end
  end

  def stop_session(_), do: :ok
```

Note: the existing tests call `AppServer.stop_session(%{port: port})` without
the other session fields, so the second function head preserves that path
(no log). The first head is used when a full session map is passed, which is
what AgentRunner does.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd elixir && mix test test/symphony_elixir/claude/app_server_test.exs`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/claude/app_server.ex elixir/test/symphony_elixir/claude/app_server_test.exs
git commit -m "feat(claude): log AppServer session lifecycle with issue context"
```

---

### Task 4: Subprocess spawn log and debug-gated wrapper events

**Files:**
- Modify: `elixir/lib/symphony_elixir/claude/app_server.ex`

No new tests: these are observational logs whose correctness is verified by
reading real logs from a `--debug` run. The existing lifecycle tests already
guarantee the code path is exercised.

- [ ] **Step 1: Add spawn log and debug-gated event log**

In `elixir/lib/symphony_elixir/claude/app_server.ex`, modify `open_port/4` to
log the spawn details and to merge stderr into stdout:

```elixir
  defp open_port(executable, args, workspace, env) do
    resolved_args = args_with_workspace(args, workspace)

    Logger.info(
      "Spawning Claude wrapper executable=#{executable} args=#{inspect(resolved_args)} cwd=#{workspace} env_keys=#{inspect(Enum.map(env, &elem(&1, 0)))}"
    )

    port =
      Port.open(
        {:spawn_executable, to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, Enum.map(resolved_args, &to_charlist/1)},
          {:cd, to_charlist(workspace)},
          {:env, Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)},
          {:line, 1_048_576}
        ]
      )

    {:ok, port}
  rescue
    e -> {:error, {:port_open_failed, Exception.message(e)}}
  end
```

Modify `handle_line/3` to log each decoded event at debug, gated by
`:debug_mode`. Replace the function with:

```elixir
  defp handle_line(port, line, on_message) do
    maybe_log_wrapper_line(line)

    case Jason.decode(line) do
      {:ok, %{"event" => event} = ev} when is_binary(event) ->
        message = normalize_event(ev)
        on_message.(message)

        case event do
          "turn_end" ->
            {:ok, %{session_id: Map.get(ev, "session_id")}}

          "session_end" ->
            {:error, {:session_ended, Map.get(ev, "reason", "unknown"), Map.get(ev, "detail")}}

          _ ->
            read_until_turn_end(port, "", on_message)
        end

      {:ok, _} ->
        read_until_turn_end(port, "", on_message)

      {:error, _} ->
        if debug_mode?() do
          Logger.debug("Claude wrapper stderr: #{line}")
        else
          Logger.warning("Claude wrapper emitted unparseable line: #{inspect(line)}")
        end

        read_until_turn_end(port, "", on_message)
    end
  end

  defp maybe_log_wrapper_line(line) do
    if debug_mode?() do
      preview = line |> String.slice(0, 200)
      Logger.debug("Claude wrapper line: #{preview}")
    end

    :ok
  end

  defp debug_mode? do
    Application.get_env(:symphony_elixir, :debug_mode, false) == true
  end
```

- [ ] **Step 2: Run all Claude AppServer tests to check no regression**

Run: `cd elixir && mix test test/symphony_elixir/claude/app_server_test.exs`
Expected: all tests pass. The `:stderr_to_stdout` change is safe because the
fake wrapper does not emit stderr.

- [ ] **Step 3: Compile check**

Run: `cd elixir && mix compile --warnings-as-errors`
Expected: `Compiled ...` with no warnings.

- [ ] **Step 4: Commit**

```bash
git add elixir/lib/symphony_elixir/claude/app_server.ex
git commit -m "feat(claude): log wrapper spawn and debug-gated event stream"
```

---

### Task 5: AgentRunner forwards issue context and logs backend selection

**Files:**
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`

No new tests — `agent_runner_test.exs` does not exist in the tree, and the
lifecycle tests in `claude/app_server_test.exs` already assert the log lines
render with the context. This task is verified by running the full suite and
by reading logs from a real `--debug` run.

- [ ] **Step 1: Log backend selection and success; forward issue context**

In `elixir/lib/symphony_elixir/agent_runner.ex`, replace the `run_codex_turns/5`
function:

```elixir
  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    app_server = AgentBackend.app_server_module()
    backend = Config.settings!().agent.backend

    Logger.info(
      "Agent backend selected backend=#{inspect(backend)} module=#{inspect(app_server)} #{issue_context(issue)}"
    )

    start_opts = [
      worker_host: worker_host,
      issue_id: Map.get(issue, :id),
      issue_identifier: Map.get(issue, :identifier)
    ]

    with {:ok, session} <- (
      result = app_server.start_session(workspace, start_opts)

      case result do
        {:ok, _session} ->
          Logger.info(
            "AppServer.start_session succeeded for #{issue_context(issue)} backend=#{inspect(backend)}"
          )

        {:error, reason} ->
          Logger.error(
            "AppServer.start_session failed: #{inspect(reason)} backend=#{inspect(app_server)}"
          )
      end

      result
    ) do
      ctx = %{app_server: app_server, session: session, workspace: workspace}

      try do
        do_run_codex_turns(ctx, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
      after
        app_server.stop_session(session)
      end
    end
  end
```

Add a per-turn debug log at the top of `do_run_codex_turns/7`. Locate the
existing function head:

```elixir
  defp do_run_codex_turns(ctx, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    %{app_server: app_server, session: app_session, workspace: workspace} = ctx
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)
```

Insert a Logger line after the `prompt = ...` line:

```elixir
    Logger.debug("Starting turn #{issue_context(issue)} turn=#{turn_number}/#{max_turns}")
```

- [ ] **Step 2: Run full test suite**

Run: `cd elixir && mix test`
Expected: all tests pass. The AgentRunner changes are additive and don't
alter behavior observable by existing tests.

- [ ] **Step 3: Compile check**

Run: `cd elixir && mix compile --warnings-as-errors`
Expected: no warnings.

- [ ] **Step 4: Commit**

```bash
git add elixir/lib/symphony_elixir/agent_runner.ex
git commit -m "feat(agent_runner): log backend selection and forward issue context"
```

---

### Task 6: Manual verification and rebuild

**Files:** none (shell verification).

- [ ] **Step 1: Rebuild the escript**

Run: `cd elixir && mix escript.build`
Expected: `Generated escript bin/symphony with MIX_ENV=dev`.

- [ ] **Step 2: Run symphony with `--debug` against the planning workflow**

Run (from the repo root):
```bash
cd elixir && ./bin/symphony workflows/planning.md --debug --port 4000 --i-understand-that-this-will-be-running-without-the-usual-guardrails > /tmp/symphony-debug.out 2>&1 &
```
Let it run ~30 seconds, then stop: `kill %1` (or the PID printed).

- [ ] **Step 3: Inspect logs for the new lines**

Run:
```bash
rg -n "Agent backend selected|AppServer.start_session succeeded|Claude session started|Spawning Claude wrapper|Claude turn starting" elixir/log/symphony.log*
```
Expected: at least one match per pattern, each with `issue_id=HA-...`
and `issue_identifier=HA-...` context where applicable. `Claude wrapper line:`
debug entries should also appear because `--debug` was set.

- [ ] **Step 4: Run once without `--debug` to confirm quiet behavior**

Run the same command without `--debug`, let it run ~30 seconds, stop it.
Then:
```bash
rg -n "Claude wrapper line:" elixir/log/symphony.log*
```
Expected: no matches (debug-gated log is silent under info level).

- [ ] **Step 5: Commit if any final touch-ups were needed**

If the verification run required no changes, there is nothing to commit for
this task.

---

## Self-Review

**Spec coverage:**
- `--debug` flag (CLI → Logger level + app env) — Task 1. ✓
- Claude.AppServer lifecycle info logs (start/failed/turn start/completed/error/stopped) — Task 3. ✓
- Debug-gated wrapper event log + `:stderr_to_stdout` — Task 4. ✓
- Subprocess spawn info log with env keys — Task 4. ✓
- AgentRunner backend-selection + start_session-success + per-turn debug — Task 5. ✓
- `start_session/2` new opts `:issue_id` / `:issue_identifier` stored on session — Task 2. ✓
- Codex.AppServer interface symmetry — Codex already accepts and ignores unknown opts; no change needed. ✓ (explicitly noted during pre-plan inspection)
- Tests: CLI flag behavior, session map fields, lifecycle log emission, failure log — Tasks 1–3. ✓

**Placeholder scan:** none — every step has concrete code, file paths, and
commands.

**Type consistency:** `log_context/1` and the session map use the same
`issue_id`, `issue_identifier`, `session_id` atoms throughout. `start_opts`
uses `:issue_id` / `:issue_identifier` matching the keyword keys read in
`start_session/2`. `debug_mode?/0` reads the same app env key
`:debug_mode` written by `maybe_enable_debug_mode/1`.

**Scope:** single plan, no decomposition needed.
