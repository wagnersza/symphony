# Live Agent Timeline — Design

**Date:** 2026-05-07
**Status:** Approved for planning
**Scope:** Add a real-time per-issue activity timeline to the Symphony operations dashboard so operators can watch agents work.

## Problem

The current dashboard at `/` shows one row per running session with reduced scalars: `last_codex_event`, `last_codex_message`, token totals, turn count. Every Codex event passes through the Orchestrator but is collapsed to "latest." Operators cannot see the agent working — only the last thing it did. Per-issue logs exist on disk (`log/symphony.log`), but `codex_session_logs` is stubbed as `[]` in the presenter and there is no UI to view them.

## Goal

Operators can click a running issue on the dashboard and see a live, scrolling transcript of every Codex event for that issue: tool calls, tool results, assistant messages, thinking blocks, token deltas, turn boundaries, and orchestrator state changes. Events appear within a few hundred ms of happening.

## Non-Goals (v1)

- Disk persistence of the timeline.
- SQLite / queryable history.
- Cross-issue timeline.
- Raw Claude stdout passthrough.
- Inline row expansion on the dashboard.
- Search/filter inside the timeline.
- Media attachments.

Each of these can be a follow-up ticket if the v1 proves useful.

## Architecture

```
                    Codex subprocess (claude -p)
                              │ stdio JSON-RPC
                              ▼
                   Codex.AppServer.handle_response
                              │ on_message callback
                              ▼
                        AgentRunner
                              │ {:codex_worker_update, id, msg}
                              ▼
              ┌───────────── Orchestrator ─────────────┐
              │  running[id]:                          │
              │    last_codex_*  (unchanged)           │
              │    timeline: Timeline.t(500)  ◀── new  │
              │                                        │
              │  on each event:                        │
              │    1. normalize via EventNormalizer    │
              │    2. assign seq + at                  │
              │    3. Timeline.append                  │
              │    4. broadcast observability:issue:<id>│
              │    5. broadcast observability:dashboard │
              └────────────────────────────────────────┘
                              │ PubSub
              ┌───────────────┼───────────────┐
              ▼                               ▼
       DashboardLive                    IssueDetailLive
       / (row becomes link)             /issues/:identifier  ◀── new
                                         ├── snapshot on mount
                                         └── stream appends
```

One new data module, one new normalizer, one new LiveView, one new route, one new PubSub topic pattern. Everything else reuses existing plumbing.

## Components

### `SymphonyElixir.Observability.Timeline` (new)

Pure data module. Ring buffer of events, newest-first rendering.

```elixir
@type event :: %{
  seq: non_neg_integer(),
  at: DateTime.t(),
  kind: :tool_call | :tool_result | :message | :thinking
       | :tokens | :turn | :state_change,
  summary: String.t(),   # one line for list view (≤200 chars)
  detail: map()          # full payload for expand
}

@spec new(pos_integer()) :: t()
@spec append(t(), event()) :: t()   # drops oldest when at capacity
@spec to_list(t()) :: [event()]     # newest-first
@spec size(t()) :: non_neg_integer()
@spec capacity(t()) :: pos_integer()
```

Capacity defaults to 500.

### `SymphonyElixir.Observability.EventNormalizer` (new)

Maps raw Codex JSON-RPC messages and orchestrator events to timeline events.

```elixir
@spec normalize(raw :: map() | tuple()) :: event_input | :ignore
```

`event_input` is the event map without `seq`/`at` — those are assigned by the Orchestrator. Unknown shapes return `:ignore`; `Logger.debug` records them so cases can be added over time. The normalizer must never crash the Orchestrator.

### `SymphonyElixir.Orchestrator` (modified)

- Add `timeline: Timeline.t()` and `next_seq: non_neg_integer()` to the running-issue struct.
- New private `record_event/3`: `(state, issue_id, raw) → state`. Normalizes, stamps `seq`/`at`, appends, broadcasts on both topics.
- Wire into the existing `handle_info({:codex_worker_update, ...})` path.
- Wire into state-transition branch points (Jira status moves, retries/attempts, PR attached, workspace created/removed) via a small helper `emit_state_event/5`.
- New read API: `issue_snapshot(issue_id) :: {:ok, snapshot} | :not_running` where `snapshot` includes header fields and `Timeline.to_list/1`.

### `SymphonyElixir.Observability.PubSub` (extended)

- Keep `broadcast_update/0` for `"observability:dashboard"` (unchanged).
- Add `broadcast_issue_event(issue_id, event)` → topic `"observability:issue:#{issue_id}"`.
- Add `subscribe_issue(issue_id)` helper so LiveViews don't build the topic string themselves.

### `SymphonyElixirWeb.IssueDetailLive` (new)

- Route: `live "/issues/:identifier", IssueDetailLive, :show`.
- `mount/3`: calls `Orchestrator.issue_snapshot(id)`, subscribes to `observability:issue:<id>` and `observability:dashboard`, initializes LiveView stream `:timeline` from the snapshot (newest-first).
- `handle_info({:timeline_event, event}, socket)`: `stream_insert(socket, :timeline, event, at: 0)`.
- `handle_info(:observability_updated, socket)`: refreshes header assigns (state, tokens, turn count, runtime) — does not touch the stream.
- When snapshot is `:not_running`, render a "No active session for <id>" banner with a back-link.

### `SymphonyElixirWeb.DashboardLive` (modified)

Each running-session row becomes `<.link navigate={~p"/issues/#{id}"}>`. No other changes.

## Data Flow

**Event lifecycle (happy path):**

1. `claude -p` prints a JSON-RPC line to stdout.
2. `Codex.AppServer.with_timeout_response/4` reads it, dispatches via `on_message` callback.
3. `AgentRunner` sends `{:codex_worker_update, issue_id, raw_msg}` to Orchestrator (unchanged).
4. Orchestrator `handle_info`:
   a. Updates existing `last_codex_*` scalars (unchanged).
   b. `EventNormalizer.normalize(raw_msg)` — if `:ignore`, stop.
   c. Assign `seq = next_seq`, stamp `at = DateTime.utc_now()`, bump `next_seq`.
   d. `timeline = Timeline.append(timeline, event)`.
   e. `ObservabilityPubSub.broadcast_issue_event(issue_id, event)`.
   f. `ObservabilityPubSub.broadcast_update()` (existing topic; fires once per event as today).
5. Any mounted `IssueDetailLive` for that id receives `{:timeline_event, event}` and `stream_insert`s.

**State transitions:** Orchestrator branch points call `emit_state_event(state, id, kind, summary, detail)` which builds a `:state_change` event and feeds it through the same append+broadcast path. State changes interleave with tool calls on a single timeline.

**Snapshot on mount:** `Orchestrator.issue_snapshot(id)` returns `{:ok, snapshot}` with header fields and `Timeline.to_list/1`, or `:not_running`.

**Ordering:** Strictly per-issue monotonic via `seq`. Cross-issue ordering is not preserved — each detail page is independent.

**Backpressure:** Orchestrator GenServer mailbox serializes events. Ring buffer drops oldest when full. LiveView streams handle high-rate inserts without re-rendering the world.

## Error Handling & Edge Cases

- **Normalizer returns unexpected shape:** pure function with catchall returning `:ignore`; `Logger.debug` records the dropped payload. Must never crash Orchestrator.
- **Issue finishes while detail page is open:** Orchestrator emits a final `:state_change`, then removes the issue from `state.running`. LiveView keeps the buffered timeline in its stream and flips header to "session ended."
- **Unknown issue identifier:** `issue_snapshot/1` returns `:not_running`; LiveView renders the "no active session" banner with a dashboard back-link.
- **Orchestrator restarts:** timelines are lost (accepted). Mounted LiveViews receive `:observability_updated`, re-snapshot; `:not_running` flips to the ended state. Users can reload to resync.
- **Large payloads:** `summary` is a string truncated to ~200 chars; `detail` holds the raw map. Worst case per issue ≈ 500 × a few KB = low single-digit MB. If growth becomes an issue, cap `detail` size in the normalizer.
- **Multiple viewers per issue:** PubSub broadcasts to all; each LiveView has its own stream.
- **High event rate (100+/sec during a turn):** LiveView streams are designed for this; broadcast cost is O(subscribers) per event.
- **No dashboard broadcast amplification:** we reuse the existing `broadcast_update/0` cadence (once per codex update, as today).

## Event Shape Details

### `:tool_call`
- `summary`: `"Read config.ex"`, `"Bash mix compile"`, `"Edit schema.ex"`
- `detail`: `%{tool: "Read", args: %{...raw...}}`

### `:tool_result`
- `summary`: `"Read config.ex ✓"` or `"Bash mix test ✗ (exit 1)"`
- `detail`: `%{tool: "Bash", ok: false, exit: 1, output: "..."}`

### `:message`
- `summary`: first ~200 chars of the assistant text.
- `detail`: `%{text: "..."}`

### `:thinking`
- `summary`: first ~200 chars of reasoning (visually dimmed in UI).
- `detail`: `%{text: "..."}`

### `:tokens`
- `summary`: `"+412 in / +128 out"`
- `detail`: `%{input: 412, output: 128, total: 540}`

### `:turn`
- `summary`: `"Turn 3 start"` or `"Turn 3 end"`
- `detail`: `%{turn: 3, phase: :start | :end}`

### `:state_change`
- `summary`: `"Jira → In Progress"`, `"attempt 2"`, `"PR #42 attached"`
- `detail`: kind-specific map.

## UI

### `/issues/:identifier` layout

```
┌─ Header ─────────────────────────────────────────────┐
│  HA-1   In Progress   attempt 1   turn 3/20          │
│  tokens 2,104 in / 887 out   runtime 4m12s           │
│  workspace: devbox:/…/symphony-workspaces/HA-1@7bdd3c│
│  [ Jira ↗ ]  [ PR ↗ ]                                │
└──────────────────────────────────────────────────────┘
┌─ Timeline (newest first, auto-scroll lock toggle) ───┐
│  21:03:20  🔧 Bash       mix compile                  │
│  21:03:18  💭 thinking   (dim, click to expand)       │
│  21:03:16  📊 tokens     +412 in / +128 out           │
│  21:03:15  🔧 Edit       schema.ex  ✓                 │
│  21:03:13  💬 message    "Checking the config…"       │
│  21:03:12  🔧 Read       config.ex                    │
│  21:03:10  ▸ state       Jira → In Progress           │
│  …                                                    │
└──────────────────────────────────────────────────────┘
```

- Header fields (state, attempt, turn, tokens, runtime, workspace, Jira/PR links) are all derivable from the existing Orchestrator running-issue struct; `runtime` is computed from `started_at` vs `now` the same way the dashboard already does it.
- Header refreshes on `:observability_updated`.
- Timeline uses Phoenix LiveView `stream/3` with `at: 0` inserts (newest first).
- Rows are one line; click to expand → shows `detail`.
- "Pause auto-scroll" toggle so reading isn't interrupted by inserts. Off by default.
- Event kinds styled via CSS classes mapped to kind — no emoji dependency.

### Dashboard

Each running-session row becomes a `<.link navigate={~p"/issues/#{id}"}>`. Nothing else changes.

## Testing

- **`TimelineTest`** — ring buffer semantics: append, capacity, drop-oldest, to_list ordering, seq monotonicity.
- **`EventNormalizerTest`** — fixture payloads from real Codex output → expected event shapes; unknown shape → `:ignore`.
- **`OrchestratorTest`** — after a `:codex_worker_update`, timeline grows by 1 and the per-issue PubSub topic receives the event; after a state transition, a `:state_change` event appears.
- **`IssueDetailLiveTest`** — mount hydrates from snapshot; inbound `:timeline_event` inserts into stream; `:not_running` renders the banner.

No new E2E tests for v1 — same bar as `SymphonyElixirWeb.DashboardLive`.

## File Layout

```
elixir/lib/symphony_elixir/observability/
  timeline.ex                   (new)
  event_normalizer.ex           (new)
  pubsub.ex                     (extended)
elixir/lib/symphony_elixir/
  orchestrator.ex               (modified)
elixir/lib/symphony_elixir_web/
  live/issue_detail_live.ex     (new)
  live/issue_detail_live.html.heex (new)
  live/dashboard_live.html.heex (row → link)
  router.ex                     (new route)
elixir/priv/static/
  dashboard.css                 (extended for timeline styles)
elixir/test/symphony_elixir/observability/
  timeline_test.exs             (new)
  event_normalizer_test.exs     (new)
elixir/test/symphony_elixir/
  orchestrator_test.exs         (extended)
elixir/test/symphony_elixir_web/
  issue_detail_live_test.exs    (new)
```

## Rollout / Follow-ups

v1 ships behind no feature flag — the dashboard link and new route are additive; old clients who hit `/` still work. Follow-up candidates (each its own ticket):

- Disk persistence of timelines for post-mortem replay.
- Search/filter within the timeline.
- Inline "mini-timeline" (last 3 events) on the dashboard row.
- Media attachments from `github-pr-media` alongside state events.
- Cross-issue unified feed for operators monitoring many agents.
