defmodule SymphonyElixir.Observability.EventNormalizerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Observability.EventNormalizer

  @ts ~U[2026-05-07 20:00:00Z]

  test "normalizes codex tool_call" do
    raw = %{
      event: "tool_call",
      timestamp: @ts,
      tool: "Read",
      args: %{path: "config.ex"}
    }

    assert %{
             kind: :tool_call,
             summary: "Read config.ex",
             detail: %{tool: "Read", args: %{path: "config.ex"}}
           } = EventNormalizer.normalize(raw)
  end

  test "normalizes codex tool_result with exit code" do
    raw = %{
      event: "tool_result",
      timestamp: @ts,
      tool: "Bash",
      ok: false,
      exit: 1,
      output: "boom"
    }

    assert %{kind: :tool_result, summary: summary, detail: detail} =
             EventNormalizer.normalize(raw)

    assert summary =~ "Bash"
    assert summary =~ "✗"
    assert detail.exit == 1
  end

  test "normalizes codex message and truncates summary" do
    long = String.duplicate("abcd", 100)

    raw = %{event: "message", timestamp: @ts, text: long}

    assert %{kind: :message, summary: summary, detail: %{text: ^long}} =
             EventNormalizer.normalize(raw)

    assert String.length(summary) <= 200
  end

  test "normalizes thinking as :thinking kind" do
    raw = %{event: "thinking", timestamp: @ts, text: "hmm"}
    assert %{kind: :thinking, summary: "hmm"} = EventNormalizer.normalize(raw)
  end

  test "normalizes tokens event into summary and detail" do
    raw = %{event: "tokens", timestamp: @ts, input: 10, output: 5, total: 15}

    assert %{
             kind: :tokens,
             summary: "+10 in / +5 out",
             detail: %{input: 10, output: 5, total: 15}
           } = EventNormalizer.normalize(raw)
  end

  test "normalizes turn_start and turn_end" do
    assert %{kind: :turn, summary: "Turn 3 start", detail: %{turn: 3, phase: :start}} =
             EventNormalizer.normalize(%{event: "turn_start", timestamp: @ts, turn: 3})

    assert %{kind: :turn, summary: "Turn 3 end", detail: %{turn: 3, phase: :end}} =
             EventNormalizer.normalize(%{event: "turn_end", timestamp: @ts, turn: 3})
  end

  test "returns :ignore for unknown event kinds" do
    assert EventNormalizer.normalize(%{event: "??", timestamp: @ts}) == :ignore
    assert EventNormalizer.normalize(%{}) == :ignore
    assert EventNormalizer.normalize(nil) == :ignore
  end

  test "build_state_event/3 builds a :state_change event" do
    ev = EventNormalizer.build_state_event(:jira_transition, "In Progress", %{from: "To Do"})

    assert %{kind: :state_change, summary: "In Progress", detail: detail} = ev
    assert detail.sub_kind == :jira_transition
    assert detail.from == "To Do"
  end

  test "never crashes on unexpected shapes" do
    # Any of these would crash a naive pattern match; normalizer must be total.
    for raw <- [%{event: 123}, %{no_event: true}, "string", 42, []] do
      assert EventNormalizer.normalize(raw) == :ignore
    end
  end
end
