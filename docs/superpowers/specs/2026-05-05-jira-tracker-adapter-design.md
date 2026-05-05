# Jira Tracker Adapter — Design

**Date:** 2026-05-05
**Status:** Approved (design); implementation plan pending
**Scope:** Add Jira Cloud as a new issue tracker alongside the existing Linear and Memory adapters in `symphony_elixir`.

## Goal

Let operators point Symphony at a Jira Cloud project instead of (or in addition to, via config) a Linear workspace, with no changes required in the orchestrator or any code that consumes `SymphonyElixir.Tracker`.

## Non-goals

- Rich-text round-tripping in comments / descriptions (plain text both ways; ADF used only as a minimal wrapper).
- Jira Server / Data Center support.
- Custom-field filtering in JQL.
- Operator-supplied raw JQL override (structured config only).
- Live E2E tests against a real Jira project in this phase.

## Approach at a glance

Jira slots in behind the existing `SymphonyElixir.Tracker` behaviour. The orchestrator and callers do not learn that Jira exists — they continue to call `Tracker.fetch_candidate_issues/0` etc. and receive `%SymphonyElixir.Tracker.Issue{}` structs. Dispatch is a new branch in `Tracker.adapter/0` keyed on `config.tracker.kind == "jira"`.

The shared issue struct is renamed out of the `Linear.*` namespace because both adapters produce the same shape.

Tracker-specific config fields move into per-kind sub-embeds (`tracker.linear.*`, `tracker.jira.*`). Shared fields (`kind`, `active_states`, `terminal_states`, `assignee`) stay at the top level. **This is a breaking config-shape change for Linear users** — existing flat fields move one level deeper. No compatibility shim is planned (YAGNI).

Transport: REST (Jira Cloud REST v3), HTTP Basic auth with `email:api_token`, via `Req` — structurally identical to the existing Linear `Req` client.

## File layout

### New files

- `elixir/lib/symphony_elixir/tracker/issue.ex` — moved from `linear/issue.ex`; module renamed to `SymphonyElixir.Tracker.Issue`. No field changes.
- `elixir/lib/symphony_elixir/jira/adapter.ex` — implements `SymphonyElixir.Tracker`.
- `elixir/lib/symphony_elixir/jira/client.ex` — `Req`-based REST v3 client.
- `test/symphony_elixir/jira/client_test.exs`
- `test/symphony_elixir/jira/adapter_test.exs`

### Modified files

- `elixir/lib/symphony_elixir/tracker.ex` — add `"jira"` dispatch branch.
- `elixir/lib/symphony_elixir/config/schema.ex` — reshape the `Tracker` embedded schema; add `Tracker.Linear` and `Tracker.Jira` sub-embeds; extend `finalize_settings/1` with Jira env-var resolution.
- `elixir/lib/symphony_elixir/linear/client.ex` — read Linear-specific config from `tracker.linear.*` instead of flat `tracker.*`.
- `elixir/lib/symphony_elixir/linear/adapter.ex` — no behavior change; only affected if it reads flat tracker fields (it reads via the client).
- `elixir/lib/symphony_elixir/tracker/memory.ex` — alias update for the renamed `Issue` struct.
- `elixir/lib/symphony_elixir/orchestrator.ex`, `status_dashboard.ex`, and any other `%Linear.Issue{}` consumers — alias update.
- `elixir/README.md` — document new config shape, Jira example, env vars.
- Existing test fixtures using flat `tracker.api_key` / `tracker.project_slug` — move fields under `tracker.linear.*`.

## Config schema

### `SymphonyElixir.Config.Schema.Tracker` (top level)

```elixir
field(:kind, :string)                              # "linear" | "jira" | "memory"
field(:active_states, {:array, :string}, default: ["Todo", "In Progress"])
field(:terminal_states, {:array, :string},
      default: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"])
field(:assignee, :string)                          # shared; "me" alias resolved per-adapter

embeds_one(:linear, Linear, defaults_to_struct: true)
embeds_one(:jira,   Jira,   defaults_to_struct: true)
```

### `Tracker.Linear` sub-embed

- `endpoint` — default `"https://api.linear.app/graphql"`
- `api_key`
- `project_slug`

### `Tracker.Jira` sub-embed (new)

- `site_url` — e.g. `"https://acme.atlassian.net"`; no default.
- `email` — account email used for Basic auth.
- `api_token` — Jira Cloud API token.
- `project_key` — e.g. `"ABC"`.

### `finalize_settings/1` changes

- `settings.tracker.linear.api_key` resolves from env `LINEAR_API_KEY` when not set in config (existing behavior, just one level deeper).
- `settings.tracker.jira.api_token` resolves from env `JIRA_API_TOKEN`.
- `settings.tracker.jira.email` resolves from env `JIRA_EMAIL`.
- `settings.tracker.assignee` resolves from `LINEAR_ASSIGNEE` when `kind == "linear"`, from `JIRA_ASSIGNEE` when `kind == "jira"`. No cross-contamination.

### Validation

Missing-credential errors are returned from the adapter/client at use time (as today with Linear's `:missing_linear_api_token`), not from the changeset. New atoms:

- `:missing_jira_credentials` — any of `site_url` / `email` / `api_token` is nil.
- `:missing_jira_project_key` — `project_key` nil.

## Jira client — `SymphonyElixir.Jira.Client`

Mirrors `Linear.Client` in shape; speaks Jira Cloud REST v3.

### Auth & base URL

- Base URL: `tracker.jira.site_url`, all paths prefixed `/rest/api/3`.
- Header: `Authorization: Basic <base64(email + ":" + api_token)>`, `Accept: application/json`, `Content-Type: application/json` on writes.
- `headers/0` returns `{:error, :missing_jira_credentials}` if any credential is nil.

### Public API

- `fetch_candidate_issues/0` — reads shared `active_states` + `assignee` + `tracker.jira.project_key`; builds JQL; paginated search; returns `{:ok, [%Tracker.Issue{}]}`.
- `fetch_issues_by_states/1` — caller-supplied state names; no assignee filter (matches Linear's behavior on this path).
- `fetch_issue_states_by_ids/1` — fetches by Jira issue keys; JQL `key in (ABC-1, ABC-2, ...)`.
- `request/4` — generic `(method, path, body, opts)` → `{:ok, decoded_body} | {:error, reason}`; used by the adapter for writes.

### JQL construction (candidate issues)

```
project = "<project_key>" AND status in ("Todo","In Progress") [AND assignee = currentUser()]
ORDER BY created ASC
```

- State names are double-quoted; any `"` inside a state name is escaped. State names containing newlines are rejected at validation time.
- `assignee == "me"` → `assignee = currentUser()` (no viewer round-trip; Jira's JQL handles it).
- `assignee` set to any other value → `assignee = "<accountId>"`. Usernames are deprecated on Jira Cloud — account IDs are required. Documented in the config docs.
- `assignee == nil` → omit the assignee clause.

### Search endpoint & pagination

- `POST /rest/api/3/search`, body:
  ```json
  {"jql": "...", "startAt": 0, "maxResults": 50,
   "fields": ["summary","description","status","priority","assignee","labels","issuelinks","created","updated"],
   "expand": ["renderedFields"]}
  ```
- `maxResults` = 50 (matches Linear's `@issue_page_size`).
- Loop until `startAt + issues.length >= total`; accumulate with the same reverse-prepend-then-reverse pattern as `Linear.Client`.

### Normalization → `%Tracker.Issue{}`

| `Issue` field | Jira source |
|---|---|
| `id` | issue `key` (e.g. `"ABC-123"`) — canonical id; used for all write-path calls |
| `identifier` | same as `id` (Jira has no separate identifier) |
| `title` | `fields.summary` |
| `description` | `fields.description` (ADF) → plain text via local `adf_to_text/1` |
| `priority` | `fields.priority.name` via static map: `"Highest"→1, "High"→2, "Medium"→3, "Low"→4, "Lowest"→5`; else `nil` |
| `state` | `fields.status.name` |
| `branch_name` | **Derived** as `"jira/" <> slug(issue.key <> "-" <> summary)`. Slug = lowercase, non-alphanumeric → `-`, collapse repeats, trim |
| `url` | `"<site_url>/browse/<key>"` |
| `assignee_id` | `fields.assignee.accountId` or `nil` |
| `labels` | `fields.labels` lowercased |
| `assigned_to_worker` | `true` if `assignee == nil`; if `assignee == "me"` we rely on the JQL `currentUser()` filter so all fetched issues are already "mine"; otherwise `accountId` equals configured `accountId` |
| `blocked_by` | `fields.issuelinks` where `type.inward == "is blocked by"`, shaped `%{id: linked.key, identifier: linked.key, state: linked.fields.status.name}` |
| `created_at`, `updated_at` | ISO8601 parse |

**ADF→text** (`adf_to_text/1`): walk the doc, handle `paragraph`, `text`, `hardBreak`, `bulletList`, `orderedList`; unknown nodes fall back to a truncated `inspect/1`. Purpose is legibility for the orchestrator and humans, not round-tripping.

### Error handling

- Non-2xx → `{:error, {:jira_api_status, status}}`; log status + truncated body. The error-body truncation helper (`summarize_error_body/1`) is currently private to `Linear.Client`; extract to `SymphonyElixir.HttpErrorLog` and have both clients use it.
- Transport failure → `{:error, {:jira_api_request, reason}}`.
- Missing credentials → `{:error, :missing_jira_credentials}`.

### Test seam

`Application.get_env(:symphony_elixir, :jira_client_module, Client)` — same pattern as Linear, so tests can swap in a fake implementing `fetch_*` + `request/4`.

## Jira adapter — `SymphonyElixir.Jira.Adapter`

Implements `SymphonyElixir.Tracker`. Reads delegate to `Jira.Client`; writes live here.

### Reads

```elixir
def fetch_candidate_issues,           do: client_module().fetch_candidate_issues()
def fetch_issues_by_states(states),   do: client_module().fetch_issues_by_states(states)
def fetch_issue_states_by_ids(ids),   do: client_module().fetch_issue_states_by_ids(ids)
```

### `create_comment(issue_key, body)`

- `POST /rest/api/3/issue/<key>/comment`, body `%{body: adf_from_text(body)}`.
- `adf_from_text/1` wraps the string minimally:
  ```elixir
  %{type: "doc", version: 1,
    content: [%{type: "paragraph",
                content: [%{type: "text", text: body}]}]}
  ```
- Returns `:ok` on 2xx (Jira returns 201). Non-2xx → `{:error, :comment_create_failed}` (matches Linear's atom) with context propagated via logs.

### `update_issue_state(issue_key, state_name)` — dynamic transition lookup

1. `GET /rest/api/3/issue/<key>/transitions?expand=transitions.fields` (the expand also returns the issue's current status so we can detect no-op in one call instead of two).
2. If current status matches `state_name` (case-insensitive, via `Config.Schema.normalize_issue_state/1`): no-op, return `:ok` (matches Linear's effective behavior where writing the same state is idempotent).
3. Otherwise, find the transition whose `to.name` equals `state_name` (case-insensitive). Match on `to.name`, **not** on the transition's own `name` — Jira workflows commonly name transitions verbs like `"Start work"` whose target status is `"In Progress"`, and callers supply the target status.
4. If found: `POST /rest/api/3/issue/<key>/transitions` with `%{transition: %{id: <id>}}`. Success on HTTP 204.
5. If not found: `{:error, :state_not_found}` — same atom Linear returns.

### Error atoms (parity with Linear)

- `:missing_jira_credentials` ↔ Linear's `:missing_linear_api_token`
- `:state_not_found` (identical)
- `{:jira_api_status, status}` / `{:jira_api_request, reason}` ↔ Linear's tuples
- `:comment_create_failed` / `:issue_update_failed` (identical atoms)

## Dispatcher change

```elixir
# elixir/lib/symphony_elixir/tracker.ex
def adapter do
  case Config.settings!().tracker.kind do
    "memory" -> SymphonyElixir.Tracker.Memory
    "jira"   -> SymphonyElixir.Jira.Adapter
    _        -> SymphonyElixir.Linear.Adapter
  end
end
```

Linear remains the default when `kind` is unset — preserves behavior for any existing config that relied on the implicit default.

## Issue struct rename

`SymphonyElixir.Linear.Issue` → `SymphonyElixir.Tracker.Issue`. Field list and `label_names/1` helper unchanged. Callers updated:

- `orchestrator.ex`
- `status_dashboard.ex`
- `linear/client.ex`
- `tracker/memory.ex`
- `linear/adapter.ex` (if it aliases)
- all affected tests

Done as a single mechanical rename commit (or part of the first implementation step) to keep diffs legible.

## Env vars

| Var | Used by |
|---|---|
| `LINEAR_API_KEY` | `tracker.linear.api_key` fallback (existing) |
| `LINEAR_ASSIGNEE` | `tracker.assignee` fallback when `kind == "linear"` (existing) |
| `JIRA_API_TOKEN` | `tracker.jira.api_token` fallback (new) |
| `JIRA_EMAIL` | `tracker.jira.email` fallback (new) |
| `JIRA_ASSIGNEE` | `tracker.assignee` fallback when `kind == "jira"` (new) |

## Tests

Structural parity with the Linear suite:

- `test/symphony_elixir/jira/client_test.exs` — stub HTTP via the `request_fun` escape hatch; cover pagination, JQL construction (quoting, `assignee = currentUser()`, no assignee), normalization (ADF→text, priority mapping, blocker extraction, branch-name slug, URL construction), and error tuples.
- `test/symphony_elixir/jira/adapter_test.exs` — fake `jira_client_module` recording calls; cover `create_comment` (ADF wrapping), `update_issue_state` (transition found → POST; not found → `:state_not_found`; current == target → no-op `:ok`), error-atom shapes.
- `test/symphony_elixir/tracker_test.exs` — extend dispatch test with a `"jira"` case.
- `test/symphony_elixir/config/schema_test.exs` — new-nested-shape parsing under `tracker.linear.*` and `tracker.jira.*`, env-var resolution for Jira secrets, validation errors when Jira fields are absent at use time.
- Update every test fixture currently using flat `tracker.api_key` / `tracker.project_slug` to the nested Linear shape.

No new live-integration target in this phase. A `jira-e2e` target analogous to `linear-e2e` can follow if needed.

## Risks / sharp edges

- **Breaking config-shape change** for Linear users. Mitigation: doc update, updated fixtures. No compatibility shim.
- **Derived `branch_name`**. Jira has no native branch-name field, so `branch_name` is synthesized (`"jira/" <> slug(...)`). Downstream code that assumes Linear-like authoritative branch names from the tracker must not treat this as authoritative for Jira.
- **ADF is lossy** on both read (description) and write (comments). Acceptable for orchestrator usage (short status comments, human-readable descriptions), explicitly out of scope to preserve formatting.
- **`assignee` requires account IDs** on Jira Cloud (usernames are deprecated). The `"me"` alias still works via `currentUser()`.
