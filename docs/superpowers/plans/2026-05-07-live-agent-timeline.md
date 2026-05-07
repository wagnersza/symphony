# Live Agent Timeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a real-time per-issue activity timeline on the Symphony operations dashboard so operators can watch agents work live.

**Architecture:** In-memory ring buffer (500 events per running issue) held inside the Orchestrator. Every Codex event (tool calls, messages, thinking, tokens, turns) plus orchestrator state changes are normalized into a common shape, appended to the buffer, and broadcast on a new per-issue PubSub topic. A new LiveView at `/issues/:identifier` hydrates from a snapshot on mount and streams appends.

**Tech Stack:** Elixir 1.19, Phoenix 1.8, Phoenix LiveView 1.1 (streams), Phoenix.PubSub 2.2, ExUnit.

**Spec:** `docs/superpowers/specs/2026-05-07-live-agent-timeline-design.md`

---

## Codebase Orientation (read before starting)

- Orchestrator GenServer: `elixir/lib/symphony_elixir/orchestrator.ex`. Owns `state.running` — a map `issue_id => metadata`. The codex update handler at lines 183-202 calls `integrate_codex_update/2` (line 1172) which today only collapses events to `last_codex_*` scalars. This is the hook point.
- Existing snapshot read API: `Orchestrator.snapshot/0` at line 1083; `handle_call(:snapshot, ...)` at line 1101 builds the map served to the dashboard.
- PubSub helper: `elixir/lib/symphony_elixir_web/observability_pubsub.ex`. Current topic: `"observability:dashboard"`. Do **not** move this module; extend it in place.
- Dashboard LiveView: `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`. 1-second tick at line 9; subscribes to pubsub at line 19.
- Router: `elixir/lib/symphony_elixir_web/router.ex`. Browser scope at lines 24-28.
- Tests live under `elixir/test/symphony_elixir/` (core logic) and `elixir/test/symphony_elixir_web/` (web/LiveView). Two-level directory `observability/` for tests does NOT yet exist; create it.
- Build/test: from the `elixir/` directory, use `mise exec -- mix test path/to/test.exs` (mise is the toolchain manager; `.env` is loaded via `mise.toml`). Running `mise exec --cd elixir -- mix ...` from repo root works too.
- Run exactly one test file at a time with the `-v` style by appending `--trace` or a line number, e.g. `mise exec --cd elixir -- mix test test/symphony_elixir/observability/timeline_test.exs:42`.

## File Structure

**Create:**
- `elixir/lib/symphony_elixir/observability/timeline.ex` — ring buffer struct + API.
- `elixir/lib/symphony_elixir/observability/event_normalizer.ex` — normalize Codex/state payloads → event shape.
- `elixir/lib/symphony_elixir_web/live/issue_detail_live.ex` — new LiveView (render inline; no separate .heex).
- `elixir/test/symphony_elixir/observability/timeline_test.exs`
- `elixir/test/symphony_elixir/observability/event_normalizer_test.exs`
- `elixir/test/symphony_elixir_web/issue_detail_live_test.exs`

**Modify:**
- `elixir/lib/symphony_elixir_web/observability_pubsub.ex` — add per-issue topic helpers.
- `elixir/lib/symphony_elixir/orchestrator.ex` — integrate timeline into codex update path + state transitions + `issue_snapshot/1`.
- `elixir/lib/symphony_elixir_web/router.ex` — new route.
- `elixir/lib/symphony_elixir_web/live/dashboard_live.ex` — row becomes a link to `/issues/:id`.
- `elixir/priv/static/dashboard.css` — timeline styles.
- `elixir/test/symphony_elixir/orchestrator_status_test.exs` — extend.

---

### Task 1: Timeline ring buffer module + tests

**Files:**
- Create: `elixir/lib/symphony_elixir/observability/timeline.ex`
- Test: `elixir/test/symphony_elixir/observability/timeline_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `elixir/test/symphony_elixir/observability/timeline_test.exs`:

```elixir
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec --cd elixir -- mix test test/symphony_elixir/observability/timeline_test.exs`
Expected: FAIL with `SymphonyElixir.Observability.Timeline.__struct__/1 is undefined` or `module ... is not loaded`.

- [ ] **Step 3: Write minimal implementation**

Create `elixir/lib/symphony_elixir/observability/timeline.ex`:

```elixir
defmodule SymphonyElixir.Observability.Timeline do
  @moduledoc """
  Fixed-capacity, newest-first ring buffer of per-issue activity events.

  Internally stored newest-first in a list; when the buffer exceeds
  capacity, the oldest (tail) entry is dropped. `to_list/1` returns
  events newest-first for direct rendering.
  """

  @enforce_keys [:capacity, :events, :size]
  defstruct capacity: 500, events: [], size: 0

  @type event :: map()
  @type t :: %__MODULE__{
          capacity: pos_integer(),
          events: [event()],
          size: non_neg_integer()
        }

  @default_capacity 500

  @spec new(pos_integer()) :: t()
  def new(capacity \\ @default_capacity)

  def new(capacity) when is_integer(capacity) and capacity > 0 do
    %__MODULE__{capacity: capacity, events: [], size: 0}
  end

  def new(capacity) do
    raise ArgumentError, "capacity must be a positive integer, got: #{inspect(capacity)}"
  end

  @spec append(t(), event()) :: t()
  def append(%__MODULE__{capacity: capacity, events: events, size: size} = tl, event)
      when is_map(event) do
    cond do
      size < capacity ->
        %{tl | events: [event | events], size: size + 1}

      true ->
        trimmed = [event | events] |> Enum.take(capacity)
        %{tl | events: trimmed, size: capacity}
    end
  end

  @spec to_list(t()) :: [event()]
  def to_list(%__MODULE__{events: events}), do: events

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{size: size}), do: size

  @spec capacity(t()) :: pos_integer()
  def capacity(%__MODULE__{capacity: capacity}), do: capacity
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec --cd elixir -- mix test test/symphony_elixir/observability/timeline_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/observability/timeline.ex \
        elixir/test/symphony_elixir/observability/timeline_test.exs
git commit -m "feat(observability): add Timeline ring buffer

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 2: EventNormalizer with fixture-driven tests

**Files:**
- Create: `elixir/lib/symphony_elixir/observability/event_normalizer.ex`
- Test: `elixir/test/symphony_elixir/observability/event_normalizer_test.exs`

Context: codex updates delivered to the Orchestrator have shape `%{event: binary, timestamp: DateTime.t(), ...}` (see `orchestrator.ex:184`). The `event` field is a string key like `"tool_call"`, `"tool_result"`, `"message"`, `"thinking"`, `"tokens"`, `"turn_start"`, `"turn_end"`. Additional payload varies. Unknown events must return `:ignore` without raising.

- [ ] **Step 1: Write the failing tests**

Create `elixir/test/symphony_elixir/observability/event_normalizer_test.exs`:

```elixir
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec --cd elixir -- mix test test/symphony_elixir/observability/event_normalizer_test.exs`
Expected: FAIL (module undefined).

- [ ] **Step 3: Write minimal implementation**

Create `elixir/lib/symphony_elixir/observability/event_normalizer.ex`:

```elixir
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
        Logger.debug(
          "EventNormalizer dropped payload: #{inspect(raw)} (#{inspect(e)})"
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
    input = Map.get(raw, :input, 0)
    output = Map.get(raw, :output, 0)
    total = Map.get(raw, :total, input + output)

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
    if String.length(str) <= @summary_limit do
      str
    else
      String.slice(str, 0, @summary_limit - 1) <> "…"
    end
  end

  defp truncate(other), do: other |> inspect() |> truncate()
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec --cd elixir -- mix test test/symphony_elixir/observability/event_normalizer_test.exs`
Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/observability/event_normalizer.ex \
        elixir/test/symphony_elixir/observability/event_normalizer_test.exs
git commit -m "feat(observability): add EventNormalizer

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 3: Extend ObservabilityPubSub with per-issue topic

**Files:**
- Modify: `elixir/lib/symphony_elixir_web/observability_pubsub.ex`
- Test: `elixir/test/symphony_elixir/observability_pubsub_test.exs` (existing file — extend)

- [ ] **Step 1: Write the failing tests**

Open `elixir/test/symphony_elixir/observability_pubsub_test.exs` and append two new tests (keep existing ones):

```elixir
  describe "per-issue events" do
    setup do
      # Issue IDs include characters like "HA-1"; test with the same shape.
      {:ok, issue_id: "HA-1"}
    end

    test "subscribe_issue/1 receives events broadcast to that issue", %{issue_id: id} do
      assert :ok = SymphonyElixirWeb.ObservabilityPubSub.subscribe_issue(id)

      event = %{seq: 1, summary: "hi", kind: :message, detail: %{text: "hi"}}
      assert :ok = SymphonyElixirWeb.ObservabilityPubSub.broadcast_issue_event(id, event)

      assert_receive {:timeline_event, ^event}
    end

    test "broadcast_issue_event/2 does not reach other issues' subscribers", %{issue_id: id} do
      :ok = SymphonyElixirWeb.ObservabilityPubSub.subscribe_issue(id)

      other_event = %{seq: 1, summary: "other", kind: :message, detail: %{text: "other"}}

      :ok =
        SymphonyElixirWeb.ObservabilityPubSub.broadcast_issue_event("OTHER-99", other_event)

      refute_receive {:timeline_event, ^other_event}, 100
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec --cd elixir -- mix test test/symphony_elixir/observability_pubsub_test.exs`
Expected: FAIL (`subscribe_issue/1`, `broadcast_issue_event/2` undefined).

- [ ] **Step 3: Extend the module**

Edit `elixir/lib/symphony_elixir_web/observability_pubsub.ex` to add per-issue helpers. Final file:

```elixir
defmodule SymphonyElixirWeb.ObservabilityPubSub do
  @moduledoc """
  PubSub helpers for observability dashboard updates and per-issue
  activity timelines.
  """

  @pubsub SymphonyElixir.PubSub
  @topic "observability:dashboard"
  @update_message :observability_updated

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @spec broadcast_update() :: :ok
  def broadcast_update do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        Phoenix.PubSub.broadcast(@pubsub, @topic, @update_message)

      _ ->
        :ok
    end
  end

  @spec subscribe_issue(String.t()) :: :ok | {:error, term()}
  def subscribe_issue(issue_id) when is_binary(issue_id) do
    Phoenix.PubSub.subscribe(@pubsub, issue_topic(issue_id))
  end

  @spec broadcast_issue_event(String.t(), map()) :: :ok
  def broadcast_issue_event(issue_id, event) when is_binary(issue_id) and is_map(event) do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        Phoenix.PubSub.broadcast(@pubsub, issue_topic(issue_id), {:timeline_event, event})

      _ ->
        :ok
    end
  end

  @spec issue_topic(String.t()) :: String.t()
  def issue_topic(issue_id) when is_binary(issue_id), do: "observability:issue:" <> issue_id
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec --cd elixir -- mix test test/symphony_elixir/observability_pubsub_test.exs`
Expected: PASS (all existing + 2 new).

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir_web/observability_pubsub.ex \
        elixir/test/symphony_elixir/observability_pubsub_test.exs
git commit -m "feat(observability): per-issue pubsub topic

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 4: Wire timeline into Orchestrator codex update path

**Files:**
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Test: `elixir/test/symphony_elixir/orchestrator_status_test.exs` (existing — add a `describe` block)

- [ ] **Step 1: Write the failing test**

Append to `elixir/test/symphony_elixir/orchestrator_status_test.exs`, inside the outer `defmodule ... do` (just above the final `end`):

```elixir
  describe "timeline integration" do
    alias SymphonyElixir.Observability.Timeline
    alias SymphonyElixirWeb.ObservabilityPubSub

    test "codex_worker_update appends to the per-issue timeline and broadcasts" do
      {:ok, server} = start_orchestrator_with_running_issue("HA-1")

      :ok = ObservabilityPubSub.subscribe_issue("HA-1")

      send(
        server,
        {:codex_worker_update, "HA-1",
         %{
           event: "tool_call",
           timestamp: ~U[2026-05-07 20:00:00Z],
           tool: "Read",
           args: %{path: "config.ex"}
         }}
      )

      assert_receive {:timeline_event,
                      %{kind: :tool_call, summary: "Read config.ex", seq: 1}}

      snapshot = SymphonyElixir.Orchestrator.issue_snapshot(server, "HA-1")

      assert {:ok, %{timeline: [%{seq: 1, kind: :tool_call}]}} = snapshot
    end

    test "issue_snapshot/1 returns :not_running for unknown issue" do
      {:ok, server} = start_orchestrator_with_running_issue("HA-1")

      assert :not_running =
               SymphonyElixir.Orchestrator.issue_snapshot(server, "HA-99")
    end
  end
```

If a `start_orchestrator_with_running_issue/1` helper does not already exist in this test file, reuse whatever helper the existing tests use to boot an Orchestrator with a seeded running issue. Search for `start_supervised!` or a helper in this file's setup; replicate the pattern. If no such helper exists, add a minimal one in a `setup_all` or a `defp` at the bottom of the module, using `start_supervised!({SymphonyElixir.Orchestrator, test_opts})` with stubbed tracker — match the style of the first test in this file.

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec --cd elixir -- mix test test/symphony_elixir/orchestrator_status_test.exs --only timeline_integration`
(or without the filter; the test name will narrow it). Expected: FAIL on `issue_snapshot/2` undefined and/or on timeline being missing.

- [ ] **Step 3: Modify the orchestrator**

Edit `elixir/lib/symphony_elixir/orchestrator.ex`:

**3a. Add aliases at the top of the module (near other `alias` lines).** Add these two:

```elixir
  alias SymphonyElixir.Observability.{EventNormalizer, Timeline}
  alias SymphonyElixirWeb.ObservabilityPubSub
```

If `ObservabilityPubSub` is already aliased for `notify_dashboard/0`, do not duplicate it — just add the Observability one.

**3b. Extend the codex update handler at lines 183-202.** Change:

```elixir
  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end
```

to:

```elixir
  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        updated_running_entry =
          record_timeline_event(updated_running_entry, issue_id, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end
```

**3c. Add timeline helpers at the bottom of the module (above the final `end`):**

```elixir
  # ---- Observability timeline integration ----

  defp record_timeline_event(running_entry, issue_id, raw_update) do
    case EventNormalizer.normalize(raw_update) do
      :ignore -> running_entry
      event -> append_and_broadcast(running_entry, issue_id, event)
    end
  end

  defp append_and_broadcast(running_entry, issue_id, event_input) do
    {timeline, next_seq} = ensure_timeline(running_entry)
    event = Map.merge(event_input, %{seq: next_seq, at: DateTime.utc_now()})
    updated_timeline = Timeline.append(timeline, event)

    ObservabilityPubSub.broadcast_issue_event(issue_id, event)

    running_entry
    |> Map.put(:timeline, updated_timeline)
    |> Map.put(:timeline_next_seq, next_seq + 1)
  end

  defp ensure_timeline(running_entry) do
    timeline = Map.get(running_entry, :timeline) || Timeline.new()
    next_seq = Map.get(running_entry, :timeline_next_seq, 1)
    {timeline, next_seq}
  end

  @spec issue_snapshot(String.t()) :: {:ok, map()} | :not_running | :unavailable
  def issue_snapshot(issue_id), do: issue_snapshot(__MODULE__, issue_id)

  @spec issue_snapshot(GenServer.server(), String.t()) ::
          {:ok, map()} | :not_running | :unavailable
  def issue_snapshot(server, issue_id) when is_binary(issue_id) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, {:issue_snapshot, issue_id}, 5_000)
      catch
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call({:issue_snapshot, issue_id}, _from, state) do
    reply =
      case Map.get(state.running, issue_id) do
        nil ->
          :not_running

        entry ->
          {timeline, _next_seq} = ensure_timeline(entry)

          {:ok,
           %{
             issue_id: issue_id,
             identifier: Map.get(entry, :identifier, issue_id),
             state: get_in(entry, [:issue, :state]),
             started_at: Map.get(entry, :started_at),
             turn_count: Map.get(entry, :turn_count, 0),
             codex_input_tokens: Map.get(entry, :codex_input_tokens, 0),
             codex_output_tokens: Map.get(entry, :codex_output_tokens, 0),
             codex_total_tokens: Map.get(entry, :codex_total_tokens, 0),
             last_codex_event: Map.get(entry, :last_codex_event),
             last_codex_message: Map.get(entry, :last_codex_message),
             last_codex_timestamp: Map.get(entry, :last_codex_timestamp),
             workspace_path: Map.get(entry, :workspace_path),
             worker_host: Map.get(entry, :worker_host),
             timeline: Timeline.to_list(timeline)
           }}
      end

    {:reply, reply, state}
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```
mise exec --cd elixir -- mix test test/symphony_elixir/orchestrator_status_test.exs
```
Expected: all existing tests + the two new ones PASS.

If existing test setup does not expose `start_orchestrator_with_running_issue/1`, inspect the first passing test in the file and replicate its seeding pattern inside the new `describe` block.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/orchestrator.ex \
        elixir/test/symphony_elixir/orchestrator_status_test.exs
git commit -m "feat(orchestrator): record timeline events per running issue

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 5: Emit state-change timeline events from orchestrator transitions

**Files:**
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Test: `elixir/test/symphony_elixir/orchestrator_status_test.exs`

Context: the orchestrator already moves issues through states and performs retries (see callsites of `update_issue(...)` and retry scheduling in `orchestrator.ex`). We want each transition to also append a `:state_change` event so operators see status moves interleaved with tool calls.

- [ ] **Step 1: Write the failing test**

Append a third test inside the `describe "timeline integration"` block from Task 4:

```elixir
    test "emit_state_event/4 appends a :state_change event and broadcasts" do
      {:ok, server} = start_orchestrator_with_running_issue("HA-1")

      :ok = ObservabilityPubSub.subscribe_issue("HA-1")

      # Exercised via a test-only helper that directly drives the state change path.
      GenServer.call(
        server,
        {:__test_emit_state_event, "HA-1", :jira_transition, "In Progress",
         %{from: "To Do"}}
      )

      assert_receive {:timeline_event,
                      %{kind: :state_change, summary: "In Progress",
                        detail: %{sub_kind: :jira_transition, from: "To Do"}}}
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec --cd elixir -- mix test test/symphony_elixir/orchestrator_status_test.exs`
Expected: FAIL on unknown call `{:__test_emit_state_event, ...}`.

- [ ] **Step 3: Add the test-only handler and production emitter**

Edit `elixir/lib/symphony_elixir/orchestrator.ex`:

**3a. Add a production helper next to `record_timeline_event/3` (defined in Task 4):**

```elixir
  defp emit_state_event(state, issue_id, sub_kind, summary, detail \\ %{}) do
    case Map.get(state.running, issue_id) do
      nil ->
        state

      entry ->
        event_input = EventNormalizer.build_state_event(sub_kind, summary, detail)
        updated_entry = append_and_broadcast(entry, issue_id, event_input)
        notify_dashboard()
        %{state | running: Map.put(state.running, issue_id, updated_entry)}
    end
  end
```

**3b. Add a test-only call handler (guarded by `Mix.env()` at compile time is fragile across umbrella/releases; instead keep it simple and unconditional but prefix with `__test_` so it's obvious):**

```elixir
  @impl true
  def handle_call(
        {:__test_emit_state_event, issue_id, sub_kind, summary, detail},
        _from,
        state
      ) do
    state = emit_state_event(state, issue_id, sub_kind, summary, detail)
    {:reply, :ok, state}
  end
```

**3c. Wire into real transitions.** For v1 we wire exactly two callsites — the two that operators most need to see. Both are inside existing functions:

- **Jira/tracker state transitions.** Search `orchestrator.ex` for `update_issue` callsites that transition the issue (e.g. to `"In Progress"`). Immediately *after* a successful transition where you have both `issue_id` and the new state string in scope, insert:

  ```elixir
  state = emit_state_event(state, issue_id, :jira_transition, new_state, %{})
  ```

  where `new_state` is the string you passed to `update_issue` (e.g. `"In Progress"`).

- **Retry attempts.** Search for the code path that increments a retry/attempt counter (the `{:retry_issue, issue_id, retry_token}` handler around line 206 and its helpers). Right after the attempt count is determined, insert:

  ```elixir
  state = emit_state_event(state, issue_id, :retry_attempt, "attempt #{attempt}", %{attempt: attempt})
  ```

  where `attempt` is the integer attempt number already in scope.

If a callsite requires plumbing not available without a larger refactor, skip it and note the skip in the commit message — this is a v1.

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec --cd elixir -- mix test test/symphony_elixir/orchestrator_status_test.exs`
Expected: PASS.

Then run the full suite to catch regressions from the transition wiring:
```
mise exec --cd elixir -- mix test
```
Expected: full suite PASS.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/orchestrator.ex \
        elixir/test/symphony_elixir/orchestrator_status_test.exs
git commit -m "feat(orchestrator): emit :state_change timeline events

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 6: IssueDetailLive — route + mount + stream append

**Files:**
- Create: `elixir/lib/symphony_elixir_web/live/issue_detail_live.ex`
- Modify: `elixir/lib/symphony_elixir_web/router.ex`
- Test: `elixir/test/symphony_elixir_web/issue_detail_live_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `elixir/test/symphony_elixir_web/issue_detail_live_test.exs`:

```elixir
defmodule SymphonyElixirWeb.IssueDetailLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  @endpoint SymphonyElixirWeb.Endpoint

  alias SymphonyElixirWeb.ObservabilityPubSub

  setup do
    start_supervised!({Phoenix.PubSub, name: SymphonyElixir.PubSub})
    start_supervised!(SymphonyElixirWeb.Endpoint)
    :ok
  end

  test "shows 'no active session' banner when issue is not running" do
    # With no Orchestrator running, issue_snapshot returns :unavailable or
    # :not_running — both should render the banner.
    {:ok, _view, html} = live(build_conn(), "/issues/HA-404")
    assert html =~ "No active session"
    assert html =~ "HA-404"
  end

  test "appends events received on the per-issue topic" do
    # Spawn a tiny fake that claims to be the orchestrator's snapshot source
    # via PubSub, then broadcast a timeline event and assert render.
    {:ok, view, _html} = live(build_conn(), "/issues/HA-1")

    event = %{
      seq: 1,
      at: ~U[2026-05-07 21:03:20Z],
      kind: :tool_call,
      summary: "Bash mix compile",
      detail: %{tool: "Bash", args: %{command: "mix compile"}}
    }

    :ok = ObservabilityPubSub.broadcast_issue_event("HA-1", event)

    html = render(view)
    assert html =~ "Bash mix compile"
  end

  defp build_conn, do: Phoenix.ConnTest.build_conn()
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec --cd elixir -- mix test test/symphony_elixir_web/issue_detail_live_test.exs`
Expected: FAIL (route or LiveView missing).

- [ ] **Step 3: Add the route**

Edit `elixir/lib/symphony_elixir_web/router.ex`. Change:

```elixir
  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
  end
```

to:

```elixir
  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
    live("/issues/:identifier", IssueDetailLive, :show)
  end
```

- [ ] **Step 4: Create the LiveView**

Create `elixir/lib/symphony_elixir_web/live/issue_detail_live.ex`:

```elixir
defmodule SymphonyElixirWeb.IssueDetailLive do
  @moduledoc """
  Live per-issue activity timeline. Subscribes to the issue's PubSub
  topic and renders each incoming event newest-first via LiveView streams.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixirWeb.ObservabilityPubSub

  @impl true
  def mount(%{"identifier" => identifier}, _session, socket) do
    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe_issue(identifier)
      :ok = ObservabilityPubSub.subscribe()
    end

    snapshot = Orchestrator.issue_snapshot(identifier)

    socket =
      socket
      |> assign(:identifier, identifier)
      |> assign_snapshot(snapshot)
      |> stream(:timeline, initial_timeline(snapshot), dom_id: &timeline_dom_id/1)

    {:ok, socket}
  end

  @impl true
  def handle_info({:timeline_event, event}, socket) do
    {:noreply, stream_insert(socket, :timeline, event, at: 0)}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    snapshot = Orchestrator.issue_snapshot(socket.assigns.identifier)
    {:noreply, assign_snapshot(socket, snapshot)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Symphony Observability</p>
            <h1 class="hero-title"><%= @identifier %></h1>
            <%= if @header do %>
              <p class="hero-copy">
                <strong>State:</strong> <%= @header.state || "—" %>
                · <strong>Turn:</strong> <%= @header.turn_count %>
                · <strong>Tokens:</strong>
                <%= @header.codex_input_tokens %> in /
                <%= @header.codex_output_tokens %> out
              </p>
            <% else %>
              <p class="hero-copy">No active session for <%= @identifier %>.</p>
            <% end %>
          </div>
        </div>
      </header>

      <section class="timeline-card" id="timeline" phx-update="stream">
        <div :for={{dom_id, ev} <- @streams.timeline} id={dom_id} class={"timeline-row kind-#{ev.kind}"}>
          <span class="timeline-time"><%= format_time(ev.at) %></span>
          <span class="timeline-kind"><%= ev.kind %></span>
          <span class="timeline-summary"><%= ev.summary %></span>
        </div>
      </section>
    </section>
    """
  end

  defp assign_snapshot(socket, {:ok, snap}), do: assign(socket, :header, snap)
  defp assign_snapshot(socket, _), do: assign(socket, :header, nil)

  defp initial_timeline({:ok, %{timeline: timeline}}) when is_list(timeline), do: timeline
  defp initial_timeline(_), do: []

  defp timeline_dom_id(%{seq: seq}), do: "event-#{seq}"

  defp format_time(%DateTime{} = dt) do
    dt
    |> DateTime.to_time()
    |> Time.to_string()
    |> String.slice(0, 8)
  end

  defp format_time(_), do: ""
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mise exec --cd elixir -- mix test test/symphony_elixir_web/issue_detail_live_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add elixir/lib/symphony_elixir_web/live/issue_detail_live.ex \
        elixir/lib/symphony_elixir_web/router.ex \
        elixir/test/symphony_elixir_web/issue_detail_live_test.exs
git commit -m "feat(web): add IssueDetailLive timeline view

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 7: Dashboard row → link to detail page

**Files:**
- Modify: `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`

This is a pure template tweak: each running-session row in the existing table becomes a `<.link>` to `/issues/:identifier`. No new tests — the existing `live_e2e_test.exs` continues to assert row rendering; we only add a wrapping link.

- [ ] **Step 1: Locate the running-session row**

Open `elixir/lib/symphony_elixir_web/live/dashboard_live.ex` and find the loop over `@payload.running` (around the running-sessions table body). Inside the row, find the cell that displays the issue identifier (probably `<%= row.identifier %>` or similar).

- [ ] **Step 2: Wrap the identifier cell in a LiveView navigate link**

Change the identifier rendering to:

```elixir
<.link navigate={~p"/issues/#{row.identifier}"} class="timeline-link">
  <%= row.identifier %>
</.link>
```

(If the file does not already import `~p` via `use SymphonyElixirWeb, :live_view` or similar, use `Routes.live_path(@socket, SymphonyElixirWeb.IssueDetailLive, row.identifier)` — grep the existing file for how other templates build paths and match that style.)

- [ ] **Step 3: Run the suite**

Run: `mise exec --cd elixir -- mix test`
Expected: full suite PASS.

- [ ] **Step 4: Manual smoke test**

Start the app:
```
mise exec --cd elixir -- ./bin/symphony workflows/planning.md --port 4000 --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

Open `http://localhost:4000/`. Click a running-session identifier. You should land on `/issues/<id>` with a header and (if the agent is active) events streaming. If no agents are running, you should see the "No active session" banner. Note anything weird.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir_web/live/dashboard_live.ex
git commit -m "feat(dashboard): link running-session row to detail page

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 8: Timeline CSS polish

**Files:**
- Modify: `elixir/priv/static/dashboard.css`

- [ ] **Step 1: Append timeline styles**

Append to `elixir/priv/static/dashboard.css`:

```css
/* ---- Live timeline ---- */

.timeline-card {
  margin-top: 1.5rem;
  padding: 1rem;
  border-radius: 12px;
  background: var(--surface, #0f172a);
  color: var(--on-surface, #e2e8f0);
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 0.85rem;
  max-height: 70vh;
  overflow-y: auto;
}

.timeline-row {
  display: grid;
  grid-template-columns: 72px 96px 1fr;
  gap: 0.75rem;
  padding: 0.25rem 0;
  border-bottom: 1px solid rgba(255, 255, 255, 0.04);
}

.timeline-time { color: #94a3b8; }
.timeline-kind { text-transform: uppercase; letter-spacing: 0.04em; }
.timeline-summary { white-space: pre-wrap; word-break: break-word; }

.timeline-row.kind-tool_call .timeline-kind { color: #38bdf8; }
.timeline-row.kind-tool_result .timeline-kind { color: #34d399; }
.timeline-row.kind-message .timeline-kind { color: #fbbf24; }
.timeline-row.kind-thinking { opacity: 0.65; }
.timeline-row.kind-thinking .timeline-kind { color: #a78bfa; }
.timeline-row.kind-tokens .timeline-kind { color: #64748b; }
.timeline-row.kind-turn .timeline-kind { color: #f472b6; }
.timeline-row.kind-state_change .timeline-kind { color: #fb923c; }

.timeline-link {
  color: inherit;
  text-decoration: underline dotted transparent;
  transition: text-decoration-color 120ms ease;
}

.timeline-link:hover {
  text-decoration-color: currentColor;
}
```

- [ ] **Step 2: Reload and smoke-check**

Reload `http://localhost:4000/issues/<active-id>`. Confirm events render with per-kind colors and a readable monospace grid. No test step — visual only.

- [ ] **Step 3: Commit**

```bash
git add elixir/priv/static/dashboard.css
git commit -m "style(dashboard): timeline row styles

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 9: Full regression + format/lint

- [ ] **Step 1: Full test suite**

Run:
```
mise exec --cd elixir -- mix test
```
Expected: PASS.

- [ ] **Step 2: Format check**

Run:
```
mise exec --cd elixir -- mix format --check-formatted
```
If it reports unformatted files touched by this plan, run `mix format` on them and amend the relevant commit (or add a small follow-up commit `chore: format`).

- [ ] **Step 3: Lint**

Run:
```
mise exec --cd elixir -- mix lint
```
Fix any warnings that apply to the files you edited. Do not drive-by-fix unrelated files.

- [ ] **Step 4: Final smoke test**

Restart the app and walk the happy path:

1. Dashboard loads, shows running sessions.
2. Click an identifier → lands on `/issues/<id>`.
3. Trigger activity in the agent (e.g., restart workflow or watch an in-flight session). Events appear live, newest-first.
4. Navigate to a bogus identifier `/issues/HA-404` → "No active session" banner shows.

If all green, this work is complete. No further commit unless fixups.

---

## Self-Review Notes

- **Spec coverage:**
  - Ring buffer capacity 500, newest-first → Task 1.
  - EventNormalizer with `:ignore` fallback → Task 2.
  - Per-issue PubSub topic → Task 3.
  - Orchestrator integration (ring buffer + broadcast + `issue_snapshot`) → Task 4.
  - `:state_change` events from transitions → Task 5.
  - `/issues/:identifier` LiveView + snapshot on mount + stream appends → Task 6.
  - Dashboard row becomes a link → Task 7.
  - Per-kind styling + "pause auto-scroll" toggle → Task 8 covers styling; the pause toggle is **deferred to a follow-up** to keep v1 tight (noted here explicitly).
  - Tests: Timeline, EventNormalizer, Orchestrator, IssueDetailLive → covered.

- **Placeholders:** none. Task 5 notes "skip if plumbing is not available" for a single callsite — this is not a placeholder but an explicit v1 concession; the production helper `emit_state_event/5` is fully defined.

- **Type consistency:** event shape (`seq`, `at`, `kind`, `summary`, `detail`) is used identically in Timeline tests, EventNormalizer output, Orchestrator append, PubSub broadcast, and LiveView render. `issue_snapshot/2` signature is the same across definition and call. `subscribe_issue/1` / `broadcast_issue_event/2` match between PubSub module and callers.
