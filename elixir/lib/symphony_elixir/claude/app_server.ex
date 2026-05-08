defmodule SymphonyElixir.Claude.AppServer do
  @moduledoc """
  Drives the Claude Agent SDK via a Node subprocess (`priv/claude_agent/index.mjs`).

  Public API matches `SymphonyElixir.Codex.AppServer` so callers can dispatch
  between backends via `SymphonyElixir.AgentBackend`.

  Protocol: see `docs/superpowers/specs/2026-05-07-claude-agent-backend-design.md`.
  """

  require Logger

  @type session :: %{
          port: port(),
          buffer: String.t(),
          workspace: Path.t(),
          session_id: String.t() | nil,
          worker_host: nil,
          issue_id: String.t() | nil,
          issue_identifier: String.t() | nil
        }

  @default_ready_timeout_ms 10_000

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

  @spec stop_session(session() | %{port: port()}) :: :ok
  def stop_session(%{port: port, issue_id: _, issue_identifier: _, session_id: _} = session)
      when is_port(port) do
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

        Logger.info("Claude session completed #{log_context(updated_session)}")

        {:ok, summary}

      {:error, reason} = err ->
        Logger.warning(
          "Claude session ended with error #{log_context(session)} reason=#{inspect(reason)}"
        )

        err
    end
  end

  # --- private helpers ---

  defp resolve_launch(_workspace, opts) do
    case Keyword.get(opts, :executable) do
      nil ->
        case find_node() do
          nil -> {:error, :node_not_found}
          node -> {:ok, node, default_node_args(), default_env()}
        end

      custom ->
        args = Keyword.get(opts, :args, [])
        env = Keyword.get(opts, :env, [])
        {:ok, System.find_executable(custom) || custom, args, env}
    end
  end

  # System.find_executable/1 uses the process PATH which may not include mise
  # shims when running as an escript. Fall back to well-known install locations.
  defp find_node do
    System.find_executable("node") ||
      Enum.find_value(
        [
          Path.expand("~/.local/share/mise/installs/node/20/bin/node"),
          Path.expand("~/.local/share/mise/installs/node/20.20.2/bin/node"),
          Path.expand("~/.nvm/versions/node/v20.*/bin/node"),
          "/usr/local/bin/node",
          "/opt/homebrew/bin/node"
        ],
        fn path ->
          expanded = Path.wildcard(path) |> List.first() || path
          if File.exists?(expanded), do: expanded
        end
      )
  end

  defp default_node_args do
    script = resolve_script_path()
    [script]
  end

  # When running as an escript, :code.priv_dir/1 returns a path inside the zip
  # archive that doesn't exist on disk. Fall back to a path relative to the
  # escript binary instead.
  defp resolve_script_path do
    priv_candidate =
      :code.priv_dir(:symphony_elixir)
      |> to_string()
      |> Path.join("claude_agent/index.mjs")

    if File.exists?(priv_candidate) do
      priv_candidate
    else
      :escript.script_name()
      |> to_string()
      |> Path.dirname()
      |> Path.join("../priv/claude_agent/index.mjs")
      |> Path.expand()
    end
  end

  defp default_env, do: []

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

  defp args_with_workspace(args, workspace) do
    if Enum.any?(args, &(&1 == "--workspace")) do
      args
    else
      args ++ ["--workspace", workspace]
    end
  end

  defp await_ready(port, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_ready(port, "", [], deadline)
  end

  defp do_await_ready(port, buffer, stderr_tail, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {:eol, line}}} ->
        buffer_line = buffer <> line

        case Jason.decode(buffer_line) do
          {:ok, %{"event" => "ready"}} ->
            {:ok, ""}

          {:ok, _other} ->
            do_await_ready(port, "", stderr_tail, deadline)

          {:error, _} ->
            do_await_ready(port, "", stderr_tail, deadline)
        end

      {^port, {:data, {:noeol, chunk}}} ->
        do_await_ready(port, buffer <> chunk, stderr_tail, deadline)

      {^port, {:exit_status, code}} ->
        {:error, {:wrapper_startup_failed, code, Enum.join(stderr_tail, "\n")}}
    after
      remaining ->
        Port.close(port)
        {:error, {:wrapper_startup_failed, :timeout, ""}}
    end
  end

  defp send_command(port, cmd) do
    Port.command(port, Jason.encode!(cmd) <> "\n")
    :ok
  rescue
    _ -> :ok
  end

  defp read_until_turn_end(port, buffer, on_message) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        handle_line(port, buffer <> line, on_message)

      {^port, {:data, {:noeol, chunk}}} ->
        read_until_turn_end(port, buffer <> chunk, on_message)

      {^port, {:exit_status, code}} ->
        {:error, {:wrapper_exited, code}}
    after
      300_000 ->
        {:error, :turn_timeout}
    end
  end

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

  defp normalize_event(%{"event" => event} = raw) do
    base = %{event: event, timestamp: parse_timestamp(Map.get(raw, "timestamp"))}

    raw
    |> Map.drop(["event", "timestamp"])
    |> Enum.reduce(base, fn {k, v}, acc ->
      Map.put(acc, String.to_atom(k), normalize_value(v))
    end)
  end

  defp normalize_value(v) when is_map(v) do
    for {k, val} <- v, into: %{} do
      key = if is_binary(k), do: String.to_atom(k), else: k
      {key, normalize_value(val)}
    end
  end

  defp normalize_value(v) when is_list(v), do: Enum.map(v, &normalize_value/1)
  defp normalize_value(v), do: v

  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_timestamp(_), do: DateTime.utc_now()

  defp log_context(%{issue_id: issue_id, issue_identifier: issue_identifier, session_id: session_id}) do
    "issue_id=#{issue_id} issue_identifier=#{issue_identifier} session_id=#{session_id}"
  end

  defp log_context(_), do: "issue_id= issue_identifier= session_id="
end
