defmodule SymphonyElixir.Observability.TimelineTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Observability.Timeline

  test "new/1 creates an empty timeline with the given capacity" do
    tl = Timeline.new(10)
    assert Timeline.size(tl) == 0
    assert Timeline.capacity(tl) == 10
    assert Timeline.to_list(tl) == []
  end

  test "new/0 defaults capacity to 500" do
    assert Timeline.capacity(Timeline.new()) == 500
  end

  test "append/2 adds events newest-first via to_list/1" do
    tl =
      Timeline.new(5)
      |> Timeline.append(%{seq: 1, summary: "a"})
      |> Timeline.append(%{seq: 2, summary: "b"})
      |> Timeline.append(%{seq: 3, summary: "c"})

    assert Timeline.size(tl) == 3
    assert Enum.map(Timeline.to_list(tl), & &1.seq) == [3, 2, 1]
  end

  test "append/2 drops oldest when at capacity" do
    tl =
      1..7
      |> Enum.reduce(Timeline.new(3), fn n, acc ->
        Timeline.append(acc, %{seq: n, summary: "e#{n}"})
      end)

    assert Timeline.size(tl) == 3
    assert Timeline.capacity(tl) == 3
    assert Enum.map(Timeline.to_list(tl), & &1.seq) == [7, 6, 5]
  end

  test "new/1 rejects non-positive capacity" do
    assert_raise ArgumentError, fn -> Timeline.new(0) end
    assert_raise ArgumentError, fn -> Timeline.new(-1) end
  end
end
