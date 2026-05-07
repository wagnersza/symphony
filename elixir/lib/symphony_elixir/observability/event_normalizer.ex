defmodule SymphonyElixir.Observability.EventNormalizer do
  @moduledoc """
  Maps raw Codex/Orchestrator payloads into the normalized timeline event
  shape. Must be total — any unknown input returns `:ignore` rather than
  raising, to protect the Orchestrator GenServer.

  Output shape (missing `seq` and `at` — the Orchestrator assigns those):

      %{
        kind: :tool_call | :tool_result | :message | :thinking
              | :tokens | :turn | :state_change,
        summary: String.t(),
        detail: map()
      }
  """

  require Logger

  @summary_limit 200

  @type event_input :: %{kind: atom(), summary: String.t(), detail: map()}

  @spec normalize(any()) :: event_input() | :ignore
  def normalize(raw) do
    try do
      do_normalize(raw)
    rescue
      e ->
        Logger.warning(
          "EventNormalizer dropped payload: #{inspect(raw)} — #{Exception.message(e)}\n" <>
            Exception.format_stacktrace(__STACKTRACE__)
        )

        :ignore
    end
  end

  @spec build_state_event(atom(), String.t(), map()) :: event_input()
  def build_state_event(sub_kind, summary, detail \\ %{})
      when is_atom(sub_kind) and is_binary(summary) and is_map(detail) do
    %{
      kind: :state_change,
      summary: truncate(summary),
      detail: Map.put(detail, :sub_kind, sub_kind)
    }
  end

  defp do_normalize(%{event: event} = raw) when is_binary(event) do
    case event do
      "tool_call" -> tool_call(raw)
      "tool_result" -> tool_result(raw)
      "message" -> message(raw, :message)
      "thinking" -> message(raw, :thinking)
      "tokens" -> tokens(raw)
      "turn_start" -> turn(raw, :start)
      "turn_end" -> turn(raw, :end)
      _ -> :ignore
    end
  end

  defp do_normalize(_), do: :ignore

  defp tool_call(raw) do
    tool = Map.get(raw, :tool) || Map.get(raw, "tool") || "tool"
    args = Map.get(raw, :args) || Map.get(raw, "args") || %{}

    %{
      kind: :tool_call,
      summary: truncate("#{tool} #{summarize_args(args)}"),
      detail: %{tool: tool, args: args}
    }
  end

  defp tool_result(raw) do
    tool = Map.get(raw, :tool) || Map.get(raw, "tool") || "tool"
    ok? = Map.get(raw, :ok, true)
    mark = if ok?, do: "✓", else: "✗"

    exit_suffix =
      case Map.get(raw, :exit) do
        nil -> ""
        code -> " (exit #{code})"
      end

    %{
      kind: :tool_result,
      summary: truncate("#{tool} #{mark}#{exit_suffix}"),
      detail: %{
        tool: tool,
        ok: ok?,
        exit: Map.get(raw, :exit),
        output: Map.get(raw, :output)
      }
    }
  end

  defp message(raw, kind) when kind in [:message, :thinking] do
    text = Map.get(raw, :text) || Map.get(raw, "text") || ""

    %{
      kind: kind,
      summary: truncate(text),
      detail: %{text: text}
    }
  end

  defp tokens(raw) do
    input = raw |> Map.get(:input, 0) |> to_integer()
    output = raw |> Map.get(:output, 0) |> to_integer()
    total = raw |> Map.get(:total, input + output) |> to_integer()

    %{
      kind: :tokens,
      summary: "+#{input} in / +#{output} out",
      detail: %{input: input, output: output, total: total}
    }
  end

  defp turn(raw, phase) when phase in [:start, :end] do
    turn = Map.get(raw, :turn, 0)
    word = if phase == :start, do: "start", else: "end"

    %{
      kind: :turn,
      summary: "Turn #{turn} #{word}",
      detail: %{turn: turn, phase: phase}
    }
  end

  defp summarize_args(args) when is_map(args) do
    cond do
      Map.has_key?(args, :path) -> to_string(args.path)
      Map.has_key?(args, "path") -> to_string(args["path"])
      Map.has_key?(args, :command) -> to_string(args.command)
      Map.has_key?(args, "command") -> to_string(args["command"])
      Map.has_key?(args, :pattern) -> to_string(args.pattern)
      Map.has_key?(args, "pattern") -> to_string(args["pattern"])
      true -> ""
    end
  end

  defp summarize_args(_), do: ""

  defp truncate(nil), do: ""

  defp truncate(str) when is_binary(str) do
    if byte_size(str) <= @summary_limit do
      str
    else
      case String.split_at(str, @summary_limit - 1) do
        {prefix, ""} -> prefix
        {prefix, _rest} -> prefix <> "…"
      end
    end
  end

  defp truncate(other), do: other |> inspect() |> truncate()

  defp to_integer(n) when is_integer(n), do: n
  defp to_integer(_), do: 0
end
