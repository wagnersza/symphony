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
          worker_host: nil
        }

  @default_ready_timeout_ms 10_000

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) when is_binary(workspace) do
    worker_host = Keyword.get(opts, :worker_host)

    if not is_nil(worker_host) do
      {:error, {:unsupported_worker_host, worker_host}}
    else
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
           worker_host: nil
         }}
      end
    end
  end

  @spec stop_session(session() | %{port: port()}) :: :ok
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

    cmd = %{type: "start", prompt: prompt, max_turns: 1}

    cmd =
      case session.session_id do
        nil -> cmd
        sid -> Map.put(cmd, :session_id, sid)
      end

    send_command(port, cmd)

    read_until_turn_end(port, session.buffer, on_message)
  end

  # --- private helpers ---

  defp resolve_launch(_workspace, opts) do
    case Keyword.get(opts, :executable) do
      nil ->
        case System.find_executable("node") do
          nil -> {:error, :node_not_found}
          node -> {:ok, node, default_node_args(), default_env()}
        end

      custom ->
        args = Keyword.get(opts, :args, [])
        env = Keyword.get(opts, :env, [])
        {:ok, System.find_executable(custom) || custom, args, env}
    end
  end

  defp default_node_args do
    script =
      :code.priv_dir(:symphony_elixir)
      |> to_string()
      |> Path.join("claude_agent/index.mjs")

    [script]
  end

  defp default_env, do: []

  defp open_port(executable, args, workspace, env) do
    port =
      Port.open(
        {:spawn_executable, to_charlist(executable)},
        [
          :binary,
          :exit_status,
          {:args, Enum.map(args_with_workspace(args, workspace), &to_charlist/1)},
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
        Logger.warning("Claude wrapper emitted unparseable line: #{inspect(line)}")
        read_until_turn_end(port, "", on_message)
    end
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
end
