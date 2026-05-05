# Jira Tracker Adapter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Jira Cloud as a third `SymphonyElixir.Tracker` adapter alongside Linear and Memory, using Jira REST v3.

**Architecture:** A new `SymphonyElixir.Jira.Adapter` implements the existing `Tracker` behaviour and delegates HTTP work to a thin `Req`-based `SymphonyElixir.Jira.Client`. The shared issue struct moves from `SymphonyElixir.Linear.Issue` to `SymphonyElixir.Tracker.Issue`. Tracker config is reshaped so Linear-specific fields live under `tracker.linear.*` and Jira fields under `tracker.jira.*`.

**Tech Stack:** Elixir, Ecto (embedded schemas), Req (HTTP), ExUnit. Jira Cloud REST v3, HTTP Basic auth with `email:api_token`.

**Spec:** `docs/superpowers/specs/2026-05-05-jira-tracker-adapter-design.md`

---

## Notes for the executing engineer

- **Run tests from `elixir/`**: `cd elixir && mix test path/to/test.exs`. The Makefile target `mix test` runs the whole suite.
- **Formatter**: run `mix format` before each commit. CI enforces `mix format --check-formatted` (via `make fmt-check`).
- **Ecto embedded schemas**: `defaults_to_struct: true` on `embeds_one` means the sub-embed always has a struct value, never `nil`. That matters for `tracker.jira.*` reads — you can read `.site_url` without guarding for a missing embed.
- **Test seam convention**: the Linear code uses `Application.get_env(:symphony_elixir, :linear_client_module, Client)` so tests can swap in a fake. Do the exact same thing for Jira (`:jira_client_module`).
- **Existing error-atom shapes matter**. The orchestrator treats `:state_not_found`, `:comment_create_failed`, `:issue_update_failed` as tracker-agnostic. Returning the same atoms from Jira means no orchestrator changes.
- **Commits**: commit after each task completes. Use conventional-commit prefixes (`feat:`, `refactor:`, `test:`, `docs:`) — matches the existing repo style (see `git log --oneline`).

---

## File map (what each task produces)

New files:
- `elixir/lib/symphony_elixir/tracker/issue.ex` — moved from `linear/issue.ex`
- `elixir/lib/symphony_elixir/http_error_log.ex` — shared HTTP error-body truncation helper
- `elixir/lib/symphony_elixir/jira/client.ex` — Req-based REST v3 client
- `elixir/lib/symphony_elixir/jira/adapter.ex` — `Tracker` behaviour impl
- `elixir/test/symphony_elixir/jira/client_test.exs`
- `elixir/test/symphony_elixir/jira/adapter_test.exs`

Modified files:
- `elixir/lib/symphony_elixir/config/schema.ex` — reshape `Tracker` embed, add `Jira` sub-embed
- `elixir/lib/symphony_elixir/tracker.ex` — add `"jira"` dispatch branch
- `elixir/lib/symphony_elixir/linear/client.ex` — read config from `tracker.linear.*`
- `elixir/lib/symphony_elixir/linear/issue.ex` — delete (content moved)
- `elixir/lib/symphony_elixir/linear/adapter.ex` — alias update for `Tracker.Issue`
- `elixir/lib/symphony_elixir/tracker/memory.ex` — alias update
- `elixir/lib/symphony_elixir/orchestrator.ex`, `status_dashboard.ex`, `agent_runner.ex`, `prompt_builder.ex`, `codex/dynamic_tool.ex`, `config.ex` — alias updates as needed
- `elixir/test/symphony_elixir/*_test.exs` + `elixir/test/support/test_support.exs` — alias updates and fixture reshape
- `elixir/README.md` — new config shape, Jira example, env vars

---

## Task 1: Rename `Linear.Issue` → `Tracker.Issue`

Pure rename. Zero behavior change. Do this first so later tasks reference the final name.

**Files:**
- Create: `elixir/lib/symphony_elixir/tracker/issue.ex`
- Delete: `elixir/lib/symphony_elixir/linear/issue.ex`
- Modify (alias updates): `elixir/lib/symphony_elixir/linear/client.ex`, `linear/adapter.ex`, `tracker/memory.ex`, `orchestrator.ex`, `status_dashboard.ex`, `agent_runner.ex`, `prompt_builder.ex`, `codex/dynamic_tool.ex`, `config.ex`, and any test/support file referencing `SymphonyElixir.Linear.Issue`.

- [ ] **Step 1: Create the new module file**

Write `elixir/lib/symphony_elixir/tracker/issue.ex`:

```elixir
defmodule SymphonyElixir.Tracker.Issue do
  @moduledoc """
  Normalized issue representation used by the orchestrator, produced by
  every Tracker adapter (Linear, Jira, Memory).
  """

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    blocked_by: [],
    labels: [],
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          labels: [String.t()],
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end
end
```

- [ ] **Step 2: Find every reference to the old module**

Run: `cd elixir && grep -rn "SymphonyElixir\.Linear\.Issue\|Linear\.Issue" lib test`

Expected: a list of files that either `alias` or reference the module directly. Record the list — every one needs to be updated in Step 3.

- [ ] **Step 3: Update every reference to point to `SymphonyElixir.Tracker.Issue`**

For each file found in Step 2:

- Replace `alias SymphonyElixir.Linear.Issue` with `alias SymphonyElixir.Tracker.Issue`.
- Replace `alias SymphonyElixir.{Config, Linear.Issue}` style groupings with the equivalent including `Tracker.Issue`.
- Replace fully qualified `SymphonyElixir.Linear.Issue` with `SymphonyElixir.Tracker.Issue`.
- Pattern matches on `%Issue{}` and `%__MODULE__{}` (in `tracker/memory.ex`) are unaffected if the alias is updated.

In `linear/client.ex`, the existing alias is `alias SymphonyElixir.{Config, Linear.Issue}` — rewrite as `alias SymphonyElixir.Config; alias SymphonyElixir.Tracker.Issue`.

In `tracker/memory.ex`, replace `alias SymphonyElixir.Linear.Issue` with `alias SymphonyElixir.Tracker.Issue`.

- [ ] **Step 4: Delete the old file**

Run: `rm elixir/lib/symphony_elixir/linear/issue.ex`

- [ ] **Step 5: Verify compilation and tests pass**

Run: `cd elixir && mix compile --warnings-as-errors && mix test`

Expected: clean compile, all existing tests pass. If any test fails with `UndefinedFunctionError` or `alias` errors, you missed a reference in Step 3 — re-run the grep and fix.

- [ ] **Step 6: Format and commit**

```bash
cd elixir && mix format
cd .. && git add -A
git commit -m "refactor(elixir): rename Linear.Issue to Tracker.Issue"
```

---

## Task 2: Extract shared HTTP error-body truncation helper

The Linear client has a private `summarize_error_body/1` + `truncate_error_body/1` pair. Jira's client will need the same logic. Extract into a tiny shared module so both can reuse it. Pure refactor — no behavior change.

**Files:**
- Create: `elixir/lib/symphony_elixir/http_error_log.ex`
- Create: `elixir/test/symphony_elixir/http_error_log_test.exs`
- Modify: `elixir/lib/symphony_elixir/linear/client.ex` (delete private helpers, call the new module)

- [ ] **Step 1: Write the failing test**

Create `elixir/test/symphony_elixir/http_error_log_test.exs`:

```elixir
defmodule SymphonyElixir.HttpErrorLogTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.HttpErrorLog

  describe "summarize_body/1" do
    test "collapses whitespace and inspects short binaries" do
      assert HttpErrorLog.summarize_body("  hello\n  world  ") == "\"hello world\""
    end

    test "truncates binaries longer than the max byte limit" do
      body = String.duplicate("a", 1_100)
      summary = HttpErrorLog.summarize_body(body)
      assert String.ends_with?(summary, "...<truncated>\"")
      assert byte_size(summary) < byte_size(body)
    end

    test "inspects non-binary bodies with a printable limit" do
      body = %{"errors" => [%{"message" => "boom"}]}
      summary = HttpErrorLog.summarize_body(body)
      assert is_binary(summary)
      assert summary =~ "boom"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd elixir && mix test test/symphony_elixir/http_error_log_test.exs`

Expected: FAIL with `** (UndefinedFunctionError) function SymphonyElixir.HttpErrorLog.summarize_body/1 is undefined (module SymphonyElixir.HttpErrorLog is not available)`.

- [ ] **Step 3: Write the minimal implementation**

Create `elixir/lib/symphony_elixir/http_error_log.ex`:

```elixir
defmodule SymphonyElixir.HttpErrorLog do
  @moduledoc """
  Shared helpers for safely summarizing HTTP error bodies for logging.
  """

  @max_error_body_log_bytes 1_000

  @spec summarize_body(term()) :: String.t()
  def summarize_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate()
    |> inspect()
  end

  def summarize_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate()
  end

  defp truncate(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end
end
```

- [ ] **Step 4: Run the new test to verify it passes**

Run: `cd elixir && mix test test/symphony_elixir/http_error_log_test.exs`

Expected: 3 tests, 0 failures.

- [ ] **Step 5: Refactor `Linear.Client` to use the new helper**

Edit `elixir/lib/symphony_elixir/linear/client.ex`:

- Delete the module attribute `@max_error_body_log_bytes 1_000`.
- Delete the private functions `summarize_error_body/1` (both clauses) and `truncate_error_body/1`.
- In `linear_error_context/2`, replace the line `|> summarize_error_body()` with `|> SymphonyElixir.HttpErrorLog.summarize_body()`.

- [ ] **Step 6: Run the full test suite to confirm nothing regressed**

Run: `cd elixir && mix test`

Expected: all tests pass.

- [ ] **Step 7: Format and commit**

```bash
cd elixir && mix format
cd .. && git add -A
git commit -m "refactor(elixir): extract HttpErrorLog shared helper"
```

---

## Task 3: Reshape `Config.Schema.Tracker` into per-kind sub-embeds

Top-level tracker keeps `kind`, `active_states`, `terminal_states`, `assignee`. Add `Tracker.Linear` and `Tracker.Jira` sub-embeds. Move Linear's fields (`endpoint`, `api_key`, `project_slug`) into `Tracker.Linear`. Update `finalize_settings/1` to resolve Linear *and* Jira secrets from env vars.

**Breaking change**: existing configs that set `tracker.api_key` at the top level must now set `tracker.linear.api_key`. All in-tree fixtures are updated in Task 4.

**Files:**
- Modify: `elixir/lib/symphony_elixir/config/schema.ex`

- [ ] **Step 1: Write the failing test**

Append to `elixir/test/symphony_elixir/workspace_and_config_test.exs` (at the end of the existing module, inside the outer `describe` blocks or in a new `describe`). If the file has multiple `describe` blocks, add a new one at the bottom. Insert:

```elixir
describe "Config.Schema — nested tracker config" do
  test "parses Linear settings nested under tracker.linear" do
    {:ok, settings} =
      SymphonyElixir.Config.Schema.parse(%{
        "tracker" => %{
          "kind" => "linear",
          "linear" => %{
            "endpoint" => "https://api.linear.app/graphql",
            "api_key" => "key-123",
            "project_slug" => "acme-web"
          }
        }
      })

    assert settings.tracker.kind == "linear"
    assert settings.tracker.linear.endpoint == "https://api.linear.app/graphql"
    assert settings.tracker.linear.api_key == "key-123"
    assert settings.tracker.linear.project_slug == "acme-web"
  end

  test "parses Jira settings nested under tracker.jira" do
    {:ok, settings} =
      SymphonyElixir.Config.Schema.parse(%{
        "tracker" => %{
          "kind" => "jira",
          "jira" => %{
            "site_url" => "https://acme.atlassian.net",
            "email" => "bot@example.com",
            "api_token" => "tkn-abc",
            "project_key" => "ABC"
          }
        }
      })

    assert settings.tracker.kind == "jira"
    assert settings.tracker.jira.site_url == "https://acme.atlassian.net"
    assert settings.tracker.jira.email == "bot@example.com"
    assert settings.tracker.jira.api_token == "tkn-abc"
    assert settings.tracker.jira.project_key == "ABC"
  end

  test "resolves Jira secrets from env vars when absent in config" do
    original_token = System.get_env("JIRA_API_TOKEN")
    original_email = System.get_env("JIRA_EMAIL")
    original_assignee = System.get_env("JIRA_ASSIGNEE")

    System.put_env("JIRA_API_TOKEN", "env-token")
    System.put_env("JIRA_EMAIL", "env@example.com")
    System.put_env("JIRA_ASSIGNEE", "env-assignee-id")

    try do
      {:ok, settings} =
        SymphonyElixir.Config.Schema.parse(%{
          "tracker" => %{"kind" => "jira", "jira" => %{"site_url" => "https://a.atlassian.net", "project_key" => "A"}}
        })

      assert settings.tracker.jira.api_token == "env-token"
      assert settings.tracker.jira.email == "env@example.com"
      assert settings.tracker.assignee == "env-assignee-id"
    after
      restore_env("JIRA_API_TOKEN", original_token)
      restore_env("JIRA_EMAIL", original_email)
      restore_env("JIRA_ASSIGNEE", original_assignee)
    end
  end

  defp restore_env(var, nil), do: System.delete_env(var)
  defp restore_env(var, value), do: System.put_env(var, value)
end
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `cd elixir && mix test test/symphony_elixir/workspace_and_config_test.exs -t describe:"Config.Schema — nested tracker config"`

If the selector doesn't work in your setup, just run the whole file and look for the three new failures. Expected: the new tests fail because `tracker.linear` / `tracker.jira` keys aren't parsed.

- [ ] **Step 3: Add the `Jira` sub-embed module**

In `elixir/lib/symphony_elixir/config/schema.ex`, immediately after the existing `Tracker` module block (around line 66), add a new `Tracker.Linear` module **and** a new `Tracker.Jira` module. Keep the existing `Tracker` module in place — you'll edit it in Step 4.

Insert before Task 3 Step 4's edit:

```elixir
  defmodule TrackerLinear do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:endpoint, :string, default: "https://api.linear.app/graphql")
      field(:api_key, :string)
      field(:project_slug, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:endpoint, :api_key, :project_slug], empty_values: [])
    end
  end

  defmodule TrackerJira do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:site_url, :string)
      field(:email, :string)
      field(:api_token, :string)
      field(:project_key, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:site_url, :email, :api_token, :project_key], empty_values: [])
    end
  end
```

(Naming: use `TrackerLinear` / `TrackerJira` at the top level of `Config.Schema` to avoid nesting a `Linear` module inside `Tracker` — the embedded_schema macro requires the module to be defined at the time the parent `Tracker` runs its `embeds_one`. Top-level siblings are simpler and also idiomatic in this file, which already defines `Tracker`, `Polling`, `Workspace`, etc. as siblings.)

- [ ] **Step 4: Update the `Tracker` embedded schema**

In the existing `defmodule Tracker do` block (around lines 40–66), replace its `embedded_schema` and `changeset` with:

```elixir
    embedded_schema do
      field(:kind, :string)
      field(:assignee, :string)
      field(:active_states, {:array, :string}, default: ["Todo", "In Progress"])
      field(:terminal_states, {:array, :string}, default: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"])

      embeds_one(:linear, SymphonyElixir.Config.Schema.TrackerLinear,
        on_replace: :update,
        defaults_to_struct: true
      )

      embeds_one(:jira, SymphonyElixir.Config.Schema.TrackerJira,
        on_replace: :update,
        defaults_to_struct: true
      )
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:kind, :assignee, :active_states, :terminal_states], empty_values: [])
      |> cast_embed(:linear, with: &SymphonyElixir.Config.Schema.TrackerLinear.changeset/2)
      |> cast_embed(:jira, with: &SymphonyElixir.Config.Schema.TrackerJira.changeset/2)
    end
```

Note: the fields `endpoint`, `api_key`, `project_slug` are no longer on the top-level `Tracker` — they live on `TrackerLinear`.

- [ ] **Step 5: Update `finalize_settings/1`**

In `finalize_settings/1` (around line 368), replace the `tracker = %{...}` block with:

```elixir
    tracker = settings.tracker

    tracker_linear = %{
      tracker.linear
      | api_key: resolve_secret_setting(tracker.linear.api_key, System.get_env("LINEAR_API_KEY"))
    }

    tracker_jira = %{
      tracker.jira
      | api_token: resolve_secret_setting(tracker.jira.api_token, System.get_env("JIRA_API_TOKEN")),
        email: resolve_secret_setting(tracker.jira.email, System.get_env("JIRA_EMAIL"))
    }

    assignee_env =
      case tracker.kind do
        "jira" -> System.get_env("JIRA_ASSIGNEE")
        _ -> System.get_env("LINEAR_ASSIGNEE")
      end

    tracker = %{
      tracker
      | linear: tracker_linear,
        jira: tracker_jira,
        assignee: resolve_secret_setting(tracker.assignee, assignee_env)
    }
```

And keep the existing final `%{settings | tracker: tracker, workspace: workspace, codex: codex}` line unchanged.

- [ ] **Step 6: Run the new tests and confirm they pass**

Run: `cd elixir && mix test test/symphony_elixir/workspace_and_config_test.exs`

Expected: all three new tests pass; existing schema tests in this file will likely FAIL because they still use the flat shape. That's expected — Task 4 migrates them. Do **not** fix them yet; leave the file with the failures and move on.

- [ ] **Step 7: Run full compile to confirm the schema itself is valid**

Run: `cd elixir && mix compile --warnings-as-errors`

Expected: clean compile. Failures anywhere else in the app (e.g. `linear/client.ex` failing because it reads `tracker.api_key`) are expected — Task 5 fixes them.

- [ ] **Step 8: Commit (even with broken tests elsewhere — small step)**

```bash
cd elixir && mix format
cd .. && git add -A
git commit -m "feat(elixir): add nested tracker.linear and tracker.jira config embeds"
```

---

## Task 4: Migrate existing fixtures and config reads to the nested shape

The schema now produces `tracker.linear.api_key` etc. Update every in-tree place that reads those fields, plus every test fixture that sets them under the old flat shape. This task makes the suite green again before we add Jira code.

**Files:**
- Modify: `elixir/lib/symphony_elixir/linear/client.ex` (reads of `tracker.api_key`, `tracker.endpoint`, `tracker.project_slug`)
- Modify: `elixir/test/support/test_support.exs`
- Modify: `elixir/test/symphony_elixir/core_test.exs`
- Modify: `elixir/test/symphony_elixir/extensions_test.exs`
- Modify: `elixir/test/symphony_elixir/live_e2e_test.exs`
- Modify: `elixir/test/symphony_elixir/workspace_and_config_test.exs` (any pre-existing tests that used flat fields)

- [ ] **Step 1: Migrate `linear/client.ex` reads**

In `elixir/lib/symphony_elixir/linear/client.ex`:

- In `fetch_candidate_issues/0`: replace `tracker = Config.settings!().tracker` + `tracker.api_key` + `tracker.project_slug` + `tracker.active_states` with:

```elixir
    tracker = Config.settings!().tracker
    linear = tracker.linear
    project_slug = linear.project_slug

    cond do
      is_nil(linear.api_key) ->
        {:error, :missing_linear_api_token}

      is_nil(project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_by_states(project_slug, tracker.active_states, assignee_filter)
        end
    end
```

- Repeat the same substitution in `fetch_issues_by_states/1` and `fetch_issue_states_by_ids/1` (both read `tracker.api_key` and `tracker.project_slug` today).

- In `graphql_headers/0`, change `Config.settings!().tracker.api_key` to `Config.settings!().tracker.linear.api_key`.

- In `post_graphql_request/2`, change `Config.settings!().tracker.endpoint` to `Config.settings!().tracker.linear.endpoint`.

- In `routing_assignee_filter/0`: no change — `tracker.assignee` stays at the top level.

- [ ] **Step 2: Find every remaining flat-field reader**

Run: `cd elixir && grep -rn "tracker\.api_key\|tracker\.endpoint\|tracker\.project_slug" lib test`

Expected: zero matches in `lib/`. Any matches in `test/` are fixtures — migrate them in Step 3.

- [ ] **Step 3: Update test fixtures**

For every test file that builds a settings map like:

```elixir
%{"tracker" => %{"kind" => "linear", "api_key" => "...", "project_slug" => "...", "endpoint" => "..."}}
```

Rewrite it as:

```elixir
%{"tracker" => %{"kind" => "linear", "linear" => %{"api_key" => "...", "project_slug" => "...", "endpoint" => "..."}}}
```

Files to check (from the earlier grep): `test/support/test_support.exs`, `test/symphony_elixir/core_test.exs`, `test/symphony_elixir/extensions_test.exs`, `test/symphony_elixir/live_e2e_test.exs`, `test/symphony_elixir/workspace_and_config_test.exs`.

Use `grep -n "api_key\|project_slug\|\"endpoint\"" <file>` inside each file to find the exact lines.

For any struct-shape access in tests (e.g. `settings.tracker.api_key` in assertions), update to `settings.tracker.linear.api_key`.

- [ ] **Step 4: Run the full suite**

Run: `cd elixir && mix test`

Expected: all tests pass. If any still fail with `KeyError: :api_key` or similar, you missed a fixture — repeat Step 2 until clean.

- [ ] **Step 5: Format and commit**

```bash
cd elixir && mix format
cd .. && git add -A
git commit -m "refactor(elixir): migrate Linear config reads and fixtures to tracker.linear.*"
```

---

## Task 5: Jira client — JQL builder (pure function, no HTTP)

Start the Jira client by building the pure JQL string builder with no HTTP dependency. TDD it in isolation.

**Files:**
- Create: `elixir/lib/symphony_elixir/jira/client.ex` (initial version with `build_jql/3` public for testing)
- Create: `elixir/test/symphony_elixir/jira/client_test.exs`

- [ ] **Step 1: Write failing tests**

Create `elixir/test/symphony_elixir/jira/client_test.exs`:

```elixir
defmodule SymphonyElixir.Jira.ClientTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Jira.Client

  describe "build_jql/3" do
    test "builds JQL with project and states" do
      jql = Client.build_jql("ABC", ["Todo", "In Progress"], nil)

      assert jql ==
               ~s|project = "ABC" AND status in ("Todo","In Progress") ORDER BY created ASC|
    end

    test "adds currentUser() when assignee is \"me\"" do
      jql = Client.build_jql("ABC", ["Todo"], "me")

      assert jql ==
               ~s|project = "ABC" AND status in ("Todo") AND assignee = currentUser() ORDER BY created ASC|
    end

    test "adds explicit accountId when assignee is a non-me string" do
      jql = Client.build_jql("ABC", ["Todo"], "5ff00-abc")

      assert jql ==
               ~s|project = "ABC" AND status in ("Todo") AND assignee = "5ff00-abc" ORDER BY created ASC|
    end

    test "escapes double quotes inside state names" do
      jql = Client.build_jql("ABC", [~s|Weird "state"|], nil)
      assert jql =~ ~s|status in ("Weird \\"state\\"")|
    end

    test "rejects state names containing newlines" do
      assert_raise ArgumentError, fn ->
        Client.build_jql("ABC", ["bad\nstate"], nil)
      end
    end
  end
end
```

- [ ] **Step 2: Run tests and confirm they fail**

Run: `cd elixir && mix test test/symphony_elixir/jira/client_test.exs`

Expected: FAIL with `module SymphonyElixir.Jira.Client is not available`.

- [ ] **Step 3: Write minimal client with `build_jql/3`**

Create `elixir/lib/symphony_elixir/jira/client.ex`:

```elixir
defmodule SymphonyElixir.Jira.Client do
  @moduledoc """
  Thin Jira Cloud REST v3 client for polling candidate issues and
  performing comment / transition writes on behalf of the adapter.
  """

  @spec build_jql(String.t(), [String.t()], String.t() | nil) :: String.t()
  def build_jql(project_key, state_names, assignee)
      when is_binary(project_key) and is_list(state_names) do
    Enum.each(state_names, &validate_state_name!/1)

    states_clause =
      state_names
      |> Enum.map(&quote_jql_string/1)
      |> Enum.join(",")

    base = ~s|project = "#{project_key}" AND status in (#{states_clause})|

    base
    |> maybe_append_assignee(assignee)
    |> Kernel.<>(" ORDER BY created ASC")
  end

  defp maybe_append_assignee(jql, nil), do: jql
  defp maybe_append_assignee(jql, "me"), do: jql <> " AND assignee = currentUser()"
  defp maybe_append_assignee(jql, id) when is_binary(id) do
    jql <> ~s| AND assignee = "#{id}"|
  end

  defp validate_state_name!(name) when is_binary(name) do
    if String.contains?(name, "\n") do
      raise ArgumentError, "state names must not contain newlines: #{inspect(name)}"
    end

    :ok
  end

  defp quote_jql_string(value) when is_binary(value) do
    escaped = String.replace(value, ~s|"|, ~s|\\"|)
    ~s|"#{escaped}"|
  end
end
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `cd elixir && mix test test/symphony_elixir/jira/client_test.exs`

Expected: 5 tests, 0 failures.

- [ ] **Step 5: Format and commit**

```bash
cd elixir && mix format
cd .. && git add -A
git commit -m "feat(elixir): add Jira.Client.build_jql/3"
```

---

## Task 6: Jira client — ADF <-> text helpers

Two pure helpers: `adf_to_text/1` (reading Jira descriptions) and `adf_from_text/1` (wrapping plain-text comments we send). TDD both.

**Files:**
- Modify: `elixir/lib/symphony_elixir/jira/client.ex`
- Modify: `elixir/test/symphony_elixir/jira/client_test.exs`

- [ ] **Step 1: Append failing tests**

Append inside the `ClientTest` module:

```elixir
  describe "adf_to_text/1" do
    test "returns empty string for nil" do
      assert Client.adf_to_text(nil) == ""
    end

    test "extracts a single paragraph of text" do
      adf = %{
        "type" => "doc",
        "version" => 1,
        "content" => [
          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "hello world"}]}
        ]
      }

      assert Client.adf_to_text(adf) == "hello world"
    end

    test "joins paragraphs with newlines and handles hard breaks" do
      adf = %{
        "type" => "doc",
        "content" => [
          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "line1"}, %{"type" => "hardBreak"}, %{"type" => "text", "text" => "line2"}]},
          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "para2"}]}
        ]
      }

      assert Client.adf_to_text(adf) == "line1\nline2\n\npara2"
    end

    test "renders bullet list items with a leading dash" do
      adf = %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "bulletList",
            "content" => [
              %{"type" => "listItem", "content" => [%{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "one"}]}]},
              %{"type" => "listItem", "content" => [%{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "two"}]}]}
            ]
          }
        ]
      }

      assert Client.adf_to_text(adf) == "- one\n- two"
    end
  end

  describe "adf_from_text/1" do
    test "wraps a string as a single-paragraph ADF doc" do
      assert Client.adf_from_text("hi") == %{
               "type" => "doc",
               "version" => 1,
               "content" => [
                 %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "hi"}]}
               ]
             }
    end
  end
```

- [ ] **Step 2: Run and confirm failure**

Run: `cd elixir && mix test test/symphony_elixir/jira/client_test.exs`

Expected: 6 new tests fail with `UndefinedFunctionError`.

- [ ] **Step 3: Implement both helpers in `Jira.Client`**

Append to `elixir/lib/symphony_elixir/jira/client.ex`:

```elixir
  @spec adf_to_text(map() | nil) :: String.t()
  def adf_to_text(nil), do: ""

  def adf_to_text(%{"type" => "doc", "content" => content}) when is_list(content) do
    content
    |> Enum.map(&render_block/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  def adf_to_text(_other), do: ""

  @spec adf_from_text(String.t()) :: map()
  def adf_from_text(body) when is_binary(body) do
    %{
      "type" => "doc",
      "version" => 1,
      "content" => [
        %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => body}]}
      ]
    }
  end

  defp render_block(%{"type" => "paragraph", "content" => content}) when is_list(content) do
    Enum.map_join(content, "", &render_inline/1)
  end

  defp render_block(%{"type" => "bulletList", "content" => items}) when is_list(items) do
    items |> Enum.map(&render_list_item("- ", &1)) |> Enum.join("\n")
  end

  defp render_block(%{"type" => "orderedList", "content" => items}) when is_list(items) do
    items
    |> Enum.with_index(1)
    |> Enum.map(fn {item, idx} -> render_list_item("#{idx}. ", item) end)
    |> Enum.join("\n")
  end

  defp render_block(other), do: inspect(other, limit: 10, printable_limit: 200)

  defp render_list_item(prefix, %{"type" => "listItem", "content" => content}) when is_list(content) do
    body =
      content
      |> Enum.map(&render_block/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")

    prefix <> body
  end

  defp render_list_item(prefix, _other), do: prefix

  defp render_inline(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp render_inline(%{"type" => "hardBreak"}), do: "\n"
  defp render_inline(_other), do: ""
```

- [ ] **Step 4: Run tests**

Run: `cd elixir && mix test test/symphony_elixir/jira/client_test.exs`

Expected: all tests pass.

- [ ] **Step 5: Format and commit**

```bash
cd elixir && mix format
cd .. && git add -A
git commit -m "feat(elixir): add Jira.Client ADF to/from text helpers"
```

---

## Task 7: Jira client — issue normalization

Pure function: `normalize_issue/2` takes a Jira search-response issue map + a `site_url` and returns a `%Tracker.Issue{}`. TDD the priority map, branch-name derivation, URL construction, blocker extraction, and label lowering.

**Files:**
- Modify: `elixir/lib/symphony_elixir/jira/client.ex`
- Modify: `elixir/test/symphony_elixir/jira/client_test.exs`

- [ ] **Step 1: Append failing tests**

Append:

```elixir
  describe "normalize_issue/2" do
    setup do
      {:ok,
       %{
         site_url: "https://acme.atlassian.net",
         issue: %{
           "key" => "ABC-42",
           "fields" => %{
             "summary" => "Fix the thing",
             "description" => %{"type" => "doc", "content" => [%{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "hi"}]}]},
             "status" => %{"name" => "In Progress"},
             "priority" => %{"name" => "High"},
             "assignee" => %{"accountId" => "acct-1"},
             "labels" => ["Bug", "Critical"],
             "issuelinks" => [
               %{
                 "type" => %{"inward" => "is blocked by"},
                 "inwardIssue" => %{
                   "key" => "ABC-41",
                   "fields" => %{"status" => %{"name" => "Todo"}}
                 }
               },
               %{
                 "type" => %{"inward" => "relates to"},
                 "inwardIssue" => %{
                   "key" => "ABC-40",
                   "fields" => %{"status" => %{"name" => "Done"}}
                 }
               }
             ],
             "created" => "2026-05-01T10:00:00.000+0000",
             "updated" => "2026-05-02T10:00:00.000+0000"
           }
         }
       }}
    end

    test "maps core fields", %{issue: issue, site_url: site_url} do
      result = Client.normalize_issue(issue, site_url)

      assert result.id == "ABC-42"
      assert result.identifier == "ABC-42"
      assert result.title == "Fix the thing"
      assert result.description == "hi"
      assert result.state == "In Progress"
      assert result.priority == 2
      assert result.assignee_id == "acct-1"
      assert result.url == "https://acme.atlassian.net/browse/ABC-42"
      assert result.labels == ["bug", "critical"]
    end

    test "derives branch name from key + summary", %{issue: issue, site_url: site_url} do
      result = Client.normalize_issue(issue, site_url)
      assert result.branch_name == "jira/abc-42-fix-the-thing"
    end

    test "extracts only 'is blocked by' issuelinks", %{issue: issue, site_url: site_url} do
      result = Client.normalize_issue(issue, site_url)
      assert result.blocked_by == [%{id: "ABC-41", identifier: "ABC-41", state: "Todo"}]
    end

    test "maps unknown priority names to nil" do
      issue = %{"key" => "X-1", "fields" => %{"summary" => "s", "priority" => %{"name" => "Frobnicate"}}}
      result = Client.normalize_issue(issue, "https://x.atlassian.net")
      assert result.priority == nil
    end

    test "handles missing assignee and missing priority" do
      issue = %{"key" => "X-1", "fields" => %{"summary" => "s"}}
      result = Client.normalize_issue(issue, "https://x.atlassian.net")
      assert result.assignee_id == nil
      assert result.priority == nil
    end
  end
```

- [ ] **Step 2: Run and confirm failure**

Run: `cd elixir && mix test test/symphony_elixir/jira/client_test.exs`

Expected: the 5 new tests fail (`normalize_issue/2` undefined).

- [ ] **Step 3: Implement `normalize_issue/2`**

Append to `jira/client.ex`:

```elixir
  alias SymphonyElixir.Tracker.Issue

  @priority_map %{
    "Highest" => 1,
    "High" => 2,
    "Medium" => 3,
    "Low" => 4,
    "Lowest" => 5
  }

  @spec normalize_issue(map(), String.t()) :: Issue.t()
  def normalize_issue(%{"key" => key, "fields" => fields}, site_url)
      when is_binary(key) and is_map(fields) and is_binary(site_url) do
    %Issue{
      id: key,
      identifier: key,
      title: fields["summary"],
      description: adf_to_text(fields["description"]),
      priority: map_priority(fields["priority"]),
      state: get_in(fields, ["status", "name"]),
      branch_name: derive_branch_name(key, fields["summary"]),
      url: site_url <> "/browse/" <> key,
      assignee_id: get_in(fields, ["assignee", "accountId"]),
      blocked_by: extract_blockers(fields["issuelinks"]),
      labels: extract_labels(fields["labels"]),
      assigned_to_worker: true,
      created_at: parse_datetime(fields["created"]),
      updated_at: parse_datetime(fields["updated"])
    }
  end

  defp map_priority(%{"name" => name}) when is_binary(name), do: Map.get(@priority_map, name)
  defp map_priority(_), do: nil

  defp derive_branch_name(key, summary) when is_binary(key) do
    slug_source = key <> "-" <> to_string(summary || "")

    slug =
      slug_source
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    "jira/" <> slug
  end

  defp extract_blockers(links) when is_list(links) do
    Enum.flat_map(links, fn
      %{"type" => %{"inward" => "is blocked by"}, "inwardIssue" => %{"key" => k, "fields" => %{"status" => %{"name" => state}}}} ->
        [%{id: k, identifier: k, state: state}]

      _ ->
        []
    end)
  end

  defp extract_blockers(_), do: []

  defp extract_labels(labels) when is_list(labels) do
    labels
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_), do: []

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) when is_binary(raw) do
    # Jira returns "2026-05-01T10:00:00.000+0000" — not strict ISO8601.
    # Normalize the offset from +0000 to +00:00 before parsing.
    normalized = Regex.replace(~r/([+-]\d{2})(\d{2})$/, raw, "\\1:\\2")

    case DateTime.from_iso8601(normalized) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end
```

- [ ] **Step 4: Run tests**

Run: `cd elixir && mix test test/symphony_elixir/jira/client_test.exs`

Expected: all tests pass.

- [ ] **Step 5: Format and commit**

```bash
cd elixir && mix format
cd .. && git add -A
git commit -m "feat(elixir): add Jira.Client.normalize_issue/2"
```

---

## Task 8: Jira client — HTTP layer (`request/4` + credentials header)

Add the HTTP request plumbing with a `request_fun` escape hatch so tests stub transport without hitting the network. Still no search/transitions yet — those come next.

**Files:**
- Modify: `elixir/lib/symphony_elixir/jira/client.ex`
- Modify: `elixir/test/symphony_elixir/jira/client_test.exs`

- [ ] **Step 1: Append failing tests**

Append:

```elixir
  describe "request/4" do
    setup do
      original_env = Application.get_env(:symphony_elixir, :workflow_config)
      on_exit(fn -> Application.put_env(:symphony_elixir, :workflow_config, original_env) end)

      Application.put_env(:symphony_elixir, :workflow_config, %{
        "tracker" => %{
          "kind" => "jira",
          "jira" => %{
            "site_url" => "https://acme.atlassian.net",
            "email" => "bot@example.com",
            "api_token" => "tkn",
            "project_key" => "ABC"
          }
        }
      })

      :ok
    end

    test "sends Basic-auth header, JSON body, and returns parsed body on 2xx" do
      request_fun = fn method, url, headers, body ->
        assert method == :post
        assert url == "https://acme.atlassian.net/rest/api/3/foo"
        assert {"Authorization", "Basic " <> encoded} = List.keyfind(headers, "Authorization", 0)
        assert Base.decode64!(encoded) == "bot@example.com:tkn"
        assert body == %{"hello" => "world"}
        {:ok, %{status: 200, body: %{"ok" => true}}}
      end

      assert Client.request(:post, "/foo", %{"hello" => "world"}, request_fun: request_fun) ==
               {:ok, %{"ok" => true}}
    end

    test "returns missing-credentials error when any credential is nil" do
      Application.put_env(:symphony_elixir, :workflow_config, %{
        "tracker" => %{"kind" => "jira", "jira" => %{"site_url" => "https://a.atlassian.net", "email" => "e@x", "project_key" => "A"}}
      })

      assert Client.request(:get, "/foo", nil, request_fun: fn _, _, _, _ -> flunk("should not call") end) ==
               {:error, :missing_jira_credentials}
    end

    test "returns {:jira_api_status, status} on non-2xx" do
      request_fun = fn _, _, _, _ -> {:ok, %{status: 404, body: "not found"}} end

      assert Client.request(:get, "/foo", nil, request_fun: request_fun) ==
               {:error, {:jira_api_status, 404}}
    end

    test "returns {:jira_api_request, reason} on transport error" do
      request_fun = fn _, _, _, _ -> {:error, :nxdomain} end

      assert Client.request(:get, "/foo", nil, request_fun: request_fun) ==
               {:error, {:jira_api_request, :nxdomain}}
    end
  end
```

- [ ] **Step 2: Run and confirm failure**

Run: `cd elixir && mix test test/symphony_elixir/jira/client_test.exs`

Expected: 4 new tests fail.

- [ ] **Step 3: Implement `request/4`**

Append to `jira/client.ex`:

```elixir
  require Logger
  alias SymphonyElixir.{Config, HttpErrorLog}

  @spec request(atom(), String.t(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def request(method, path, body \\ nil, opts \\ []) when is_atom(method) and is_binary(path) do
    jira = Config.settings!().tracker.jira
    request_fun = Keyword.get(opts, :request_fun, &default_request/4)

    with {:ok, headers} <- headers(jira),
         url = jira.site_url <> "/rest/api/3" <> path,
         {:ok, %{status: status, body: response_body}} when status in 200..299 <-
           request_fun.(method, url, headers, body) do
      {:ok, response_body}
    else
      {:ok, %{status: status, body: response_body}} ->
        Logger.error(
          "Jira API request failed status=#{status} path=#{path} body=" <>
            HttpErrorLog.summarize_body(response_body)
        )

        {:error, {:jira_api_status, status}}

      {:error, :missing_jira_credentials} = error ->
        error

      {:error, reason} ->
        Logger.error("Jira API request failed: #{inspect(reason)}")
        {:error, {:jira_api_request, reason}}
    end
  end

  defp headers(%{site_url: url, email: email, api_token: token})
       when is_binary(url) and is_binary(email) and is_binary(token) do
    encoded = Base.encode64(email <> ":" <> token)

    {:ok,
     [
       {"Authorization", "Basic " <> encoded},
       {"Accept", "application/json"},
       {"Content-Type", "application/json"}
     ]}
  end

  defp headers(_), do: {:error, :missing_jira_credentials}

  defp default_request(method, url, headers, body) do
    Req.request(
      method: method,
      url: url,
      headers: headers,
      json: body,
      connect_options: [timeout: 30_000]
    )
  end
```

- [ ] **Step 4: Run tests**

Run: `cd elixir && mix test test/symphony_elixir/jira/client_test.exs`

Expected: all tests pass.

- [ ] **Step 5: Format and commit**

```bash
cd elixir && mix format
cd .. && git add -A
git commit -m "feat(elixir): add Jira.Client.request/4 with credentials header"
```

---

## Task 9: Jira client — search + `fetch_*` functions with pagination

Wire `fetch_candidate_issues/0`, `fetch_issues_by_states/1`, and `fetch_issue_states_by_ids/1` on top of `request/4`, using the `Tracker` behaviour's expected return shape. Test pagination by injecting a `request_fun` that returns two pages.

**Files:**
- Modify: `elixir/lib/symphony_elixir/jira/client.ex`
- Modify: `elixir/test/symphony_elixir/jira/client_test.exs`

- [ ] **Step 1: Append failing tests**

Append:

```elixir
  describe "fetch_candidate_issues/0 (with injected request_fun)" do
    setup do
      original_env = Application.get_env(:symphony_elixir, :workflow_config)
      on_exit(fn -> Application.put_env(:symphony_elixir, :workflow_config, original_env) end)

      Application.put_env(:symphony_elixir, :workflow_config, %{
        "tracker" => %{
          "kind" => "jira",
          "assignee" => "me",
          "active_states" => ["Todo", "In Progress"],
          "jira" => %{
            "site_url" => "https://acme.atlassian.net",
            "email" => "bot@example.com",
            "api_token" => "tkn",
            "project_key" => "ABC"
          }
        }
      })

      :ok
    end

    test "paginates across multiple pages and merges results" do
      page1 = %{
        "startAt" => 0,
        "maxResults" => 2,
        "total" => 3,
        "issues" => [
          %{"key" => "ABC-1", "fields" => %{"summary" => "a", "status" => %{"name" => "Todo"}}},
          %{"key" => "ABC-2", "fields" => %{"summary" => "b", "status" => %{"name" => "Todo"}}}
        ]
      }

      page2 = %{
        "startAt" => 2,
        "maxResults" => 2,
        "total" => 3,
        "issues" => [
          %{"key" => "ABC-3", "fields" => %{"summary" => "c", "status" => %{"name" => "Todo"}}}
        ]
      }

      {:ok, agent} = Agent.start_link(fn -> [page1, page2] end)

      request_fun = fn :post, _url, _headers, body ->
        assert body["jql"] =~ ~s|project = "ABC"|
        assert body["jql"] =~ "currentUser()"
        response = Agent.get_and_update(agent, fn [h | t] -> {h, t} end)
        {:ok, %{status: 200, body: response}}
      end

      assert {:ok, issues} = Client.fetch_candidate_issues(request_fun: request_fun)
      assert Enum.map(issues, & &1.id) == ["ABC-1", "ABC-2", "ABC-3"]
    end
  end

  describe "fetch_issue_states_by_ids/1" do
    setup do
      original_env = Application.get_env(:symphony_elixir, :workflow_config)
      on_exit(fn -> Application.put_env(:symphony_elixir, :workflow_config, original_env) end)

      Application.put_env(:symphony_elixir, :workflow_config, %{
        "tracker" => %{
          "kind" => "jira",
          "jira" => %{"site_url" => "https://a.atlassian.net", "email" => "e@x", "api_token" => "t", "project_key" => "A"}
        }
      })

      :ok
    end

    test "returns {:ok, []} for empty list without hitting the network" do
      assert Client.fetch_issue_states_by_ids([], request_fun: fn _, _, _, _ -> flunk("no call") end) ==
               {:ok, []}
    end

    test "posts a JQL search with key in (...)" do
      request_fun = fn :post, _url, _headers, body ->
        assert body["jql"] =~ ~s|key in ("A-1","A-2")|
        {:ok, %{status: 200, body: %{"issues" => [%{"key" => "A-1", "fields" => %{"summary" => "s"}}], "startAt" => 0, "total" => 1, "maxResults" => 50}}}
      end

      assert {:ok, [%{id: "A-1"}]} =
               Client.fetch_issue_states_by_ids(["A-1", "A-2"], request_fun: request_fun)
    end
  end
```

- [ ] **Step 2: Run and confirm failure**

Run: `cd elixir && mix test test/symphony_elixir/jira/client_test.exs`

Expected: new tests fail (`fetch_candidate_issues/1`, `fetch_issue_states_by_ids/2` not defined with keyword opts).

- [ ] **Step 3: Implement `fetch_*` functions**

Append to `jira/client.ex`:

```elixir
  @issue_page_size 50
  @search_fields ~w(summary description status priority assignee labels issuelinks created updated)

  @spec fetch_candidate_issues(keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(opts \\ []) do
    tracker = Config.settings!().tracker
    jira = tracker.jira

    cond do
      is_nil(jira.project_key) ->
        {:error, :missing_jira_project_key}

      true ->
        jql = build_jql(jira.project_key, tracker.active_states, tracker.assignee)
        do_search(jql, jira.site_url, 0, [], opts)
    end
  end

  @spec fetch_issues_by_states([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names, opts \\ []) when is_list(state_names) do
    normalized = state_names |> Enum.map(&to_string/1) |> Enum.uniq()

    if normalized == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker
      jira = tracker.jira

      cond do
        is_nil(jira.project_key) ->
          {:error, :missing_jira_project_key}

        true ->
          jql = build_jql(jira.project_key, normalized, nil)
          do_search(jql, jira.site_url, 0, [], opts)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(ids, opts \\ []) when is_list(ids) do
    ids = Enum.uniq(ids)

    case ids do
      [] ->
        {:ok, []}

      _ ->
        jira = Config.settings!().tracker.jira
        keys_clause = ids |> Enum.map(&~s|"#{&1}"|) |> Enum.join(",")
        jql = "key in (" <> keys_clause <> ") ORDER BY created ASC"
        do_search(jql, jira.site_url, 0, [], opts)
    end
  end

  defp do_search(jql, site_url, start_at, acc, opts) do
    body = %{
      "jql" => jql,
      "startAt" => start_at,
      "maxResults" => @issue_page_size,
      "fields" => @search_fields
    }

    case request(:post, "/search", body, opts) do
      {:ok, %{"issues" => issues, "startAt" => returned_start, "maxResults" => max_results, "total" => total}} when is_list(issues) ->
        normalized = Enum.map(issues, &normalize_issue(&1, site_url))
        new_acc = acc ++ normalized
        next_start = returned_start + max_results

        if next_start >= total or issues == [] do
          {:ok, new_acc}
        else
          do_search(jql, site_url, next_start, new_acc, opts)
        end

      {:ok, _other} ->
        {:error, :jira_unknown_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Public 0-arity versions delegate to the opts-accepting variants so that the
  # Tracker behaviour's callback signature still matches.
  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues, do: fetch_candidate_issues([])

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states), do: fetch_issues_by_states(states, [])

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(ids), do: fetch_issue_states_by_ids(ids, [])
```

Note: Elixir disallows a public function defined both with and without a default argument where both clauses are reachable. Collapse by keeping **only** the `opts \\ []` variants and removing the explicit 0-arity clauses. The `Tracker` adapter will call them as `client_module().fetch_candidate_issues()` which Elixir resolves to the default-arg clause. Delete the three duplicate `def` lines at the bottom of the snippet above before compiling.

- [ ] **Step 4: Run tests**

Run: `cd elixir && mix test test/symphony_elixir/jira/client_test.exs`

Expected: all tests pass.

- [ ] **Step 5: Format and commit**

```bash
cd elixir && mix format
cd .. && git add -A
git commit -m "feat(elixir): add Jira.Client search + fetch_* pagination"
```

---

## Task 10: Jira adapter — `Tracker` behaviour impl

Write the adapter module that implements `SymphonyElixir.Tracker`. Reads delegate to `Jira.Client`. Writes (`create_comment`, `update_issue_state`) use `request/4` with ADF wrapping and transition lookup.

**Files:**
- Create: `elixir/lib/symphony_elixir/jira/adapter.ex`
- Create: `elixir/test/symphony_elixir/jira/adapter_test.exs`

- [ ] **Step 1: Write failing tests (using a fake client module)**

Create `elixir/test/symphony_elixir/jira/adapter_test.exs`:

```elixir
defmodule SymphonyElixir.Jira.AdapterTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Jira.Adapter

  defmodule FakeClient do
    @moduledoc false

    def set_transitions(key, response), do: Agent.update(__MODULE__.Agent, &Map.put(&1, {:transitions, key}, response))
    def set_post_response(response), do: Agent.update(__MODULE__.Agent, &Map.put(&1, :post_response, response))
    def calls, do: Agent.get(__MODULE__.Agent, & &1)

    def start, do: Agent.start_link(fn -> %{} end, name: __MODULE__.Agent)
    def stop, do: Agent.stop(__MODULE__.Agent)

    # matches Jira.Client.request/4 signature
    def request(:get, "/issue/" <> rest, nil, _opts) do
      {key, _} = String.split(rest, "/transitions") |> List.to_tuple() |> then(fn {k, _} -> {k, nil} end)
      resp = Agent.get(__MODULE__.Agent, &Map.get(&1, {:transitions, key}, {:error, :not_stubbed}))
      resp
    end

    def request(:post, path, body, _opts) do
      Agent.update(__MODULE__.Agent, &Map.put(&1, :last_post, {path, body}))
      Agent.get(__MODULE__.Agent, &Map.get(&1, :post_response, {:ok, %{}}))
    end

    def fetch_candidate_issues, do: {:ok, [:candidate_issues]}
    def fetch_issues_by_states(_), do: {:ok, [:by_states]}
    def fetch_issue_states_by_ids(_), do: {:ok, [:by_ids]}
  end

  setup do
    {:ok, _} = FakeClient.start()
    Application.put_env(:symphony_elixir, :jira_client_module, FakeClient)
    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :jira_client_module)
      FakeClient.stop()
    end)
    :ok
  end

  describe "reads delegate to the configured client" do
    test "fetch_candidate_issues/0" do
      assert Adapter.fetch_candidate_issues() == {:ok, [:candidate_issues]}
    end

    test "fetch_issues_by_states/1" do
      assert Adapter.fetch_issues_by_states(["Todo"]) == {:ok, [:by_states]}
    end

    test "fetch_issue_states_by_ids/1" do
      assert Adapter.fetch_issue_states_by_ids(["ABC-1"]) == {:ok, [:by_ids]}
    end
  end

  describe "create_comment/2" do
    test "posts ADF-wrapped comment and returns :ok on 2xx" do
      FakeClient.set_post_response({:ok, %{"id" => "1"}})

      assert Adapter.create_comment("ABC-1", "hello") == :ok

      {path, body} = Map.fetch!(FakeClient.calls(), :last_post)
      assert path == "/issue/ABC-1/comment"
      assert body == %{"body" => SymphonyElixir.Jira.Client.adf_from_text("hello")}
    end

    test "returns :comment_create_failed on error" do
      FakeClient.set_post_response({:error, {:jira_api_status, 500}})
      assert Adapter.create_comment("ABC-1", "x") == {:error, :comment_create_failed}
    end
  end

  describe "update_issue_state/2" do
    test "returns :ok as no-op when current status matches target" do
      FakeClient.set_transitions("ABC-1", {:ok, %{
        "transitions" => [
          %{"id" => "31", "to" => %{"name" => "Done"}}
        ]
      }})
      # no-op path: we need the current status too. Stub transitions with the current-state expand.
      FakeClient.set_transitions("ABC-1", {:ok, %{
        "transitions" => [%{"id" => "31", "to" => %{"name" => "Done"}}],
        "fields" => %{"status" => %{"name" => "In Progress"}}
      }})

      # target matches current
      FakeClient.set_transitions("ABC-1", {:ok, %{
        "transitions" => [],
        "fields" => %{"status" => %{"name" => "In Progress"}}
      }})

      assert Adapter.update_issue_state("ABC-1", "In Progress") == :ok
      # no POST should be recorded
      refute Map.has_key?(FakeClient.calls(), :last_post)
    end

    test "posts the transition when target differs and transition exists" do
      FakeClient.set_transitions("ABC-1", {:ok, %{
        "transitions" => [%{"id" => "31", "to" => %{"name" => "Done"}}],
        "fields" => %{"status" => %{"name" => "In Progress"}}
      }})
      FakeClient.set_post_response({:ok, %{}})

      assert Adapter.update_issue_state("ABC-1", "Done") == :ok

      {path, body} = Map.fetch!(FakeClient.calls(), :last_post)
      assert path == "/issue/ABC-1/transitions"
      assert body == %{"transition" => %{"id" => "31"}}
    end

    test "returns :state_not_found when no matching transition" do
      FakeClient.set_transitions("ABC-1", {:ok, %{
        "transitions" => [%{"id" => "31", "to" => %{"name" => "Done"}}],
        "fields" => %{"status" => %{"name" => "In Progress"}}
      }})

      assert Adapter.update_issue_state("ABC-1", "Blocked") == {:error, :state_not_found}
    end

    test "returns :issue_update_failed when transition POST fails" do
      FakeClient.set_transitions("ABC-1", {:ok, %{
        "transitions" => [%{"id" => "31", "to" => %{"name" => "Done"}}],
        "fields" => %{"status" => %{"name" => "Todo"}}
      }})
      FakeClient.set_post_response({:error, {:jira_api_status, 400}})

      assert Adapter.update_issue_state("ABC-1", "Done") == {:error, :issue_update_failed}
    end
  end
end
```

- [ ] **Step 2: Run and confirm failure**

Run: `cd elixir && mix test test/symphony_elixir/jira/adapter_test.exs`

Expected: FAIL with `module SymphonyElixir.Jira.Adapter is not available`.

- [ ] **Step 3: Implement the adapter**

Create `elixir/lib/symphony_elixir/jira/adapter.ex`:

```elixir
defmodule SymphonyElixir.Jira.Adapter do
  @moduledoc """
  Jira Cloud REST v3 tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Jira.Client

  @impl true
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @impl true
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @impl true
  def fetch_issue_states_by_ids(ids), do: client_module().fetch_issue_states_by_ids(ids)

  @impl true
  def create_comment(issue_key, body) when is_binary(issue_key) and is_binary(body) do
    case client_module().request(:post, "/issue/#{issue_key}/comment", %{"body" => Client.adf_from_text(body)}, []) do
      {:ok, _} -> :ok
      {:error, _reason} -> {:error, :comment_create_failed}
    end
  end

  @impl true
  def update_issue_state(issue_key, state_name)
      when is_binary(issue_key) and is_binary(state_name) do
    target = normalize(state_name)

    with {:ok, %{"transitions" => transitions} = response} <-
           client_module().request(:get, "/issue/#{issue_key}/transitions?expand=transitions.fields", nil, []),
         current = get_in(response, ["fields", "status", "name"]) do
      if is_binary(current) and normalize(current) == target do
        :ok
      else
        case find_transition(transitions, target) do
          nil ->
            {:error, :state_not_found}

          %{"id" => id} ->
            case client_module().request(:post, "/issue/#{issue_key}/transitions", %{"transition" => %{"id" => id}}, []) do
              {:ok, _} -> :ok
              {:error, _} -> {:error, :issue_update_failed}
            end
        end
      end
    else
      {:ok, _other} -> {:error, :state_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_transition(transitions, target) when is_list(transitions) do
    Enum.find(transitions, fn
      %{"to" => %{"name" => name}} when is_binary(name) -> normalize(name) == target
      _ -> false
    end)
  end

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()

  defp client_module do
    Application.get_env(:symphony_elixir, :jira_client_module, Client)
  end
end
```

- [ ] **Step 4: Run tests**

Run: `cd elixir && mix test test/symphony_elixir/jira/adapter_test.exs`

Expected: all tests pass. If the FakeClient's `request/4` path parsing breaks, simplify it: use exact-path pattern matches on the two Jira paths (`"/issue/ABC-1/transitions?expand=transitions.fields"` and `"/issue/ABC-1/transitions"`) — matches the calls the adapter actually makes.

- [ ] **Step 5: Format and commit**

```bash
cd elixir && mix format
cd .. && git add -A
git commit -m "feat(elixir): add Jira.Adapter implementing Tracker behaviour"
```

---

## Task 11: Wire `"jira"` into the Tracker dispatcher

**Files:**
- Modify: `elixir/lib/symphony_elixir/tracker.ex`
- Modify: `elixir/test/symphony_elixir/workspace_and_config_test.exs` (or wherever the dispatch test lives; if none, extend `extensions_test.exs`)

- [ ] **Step 1: Find the existing dispatch test**

Run: `cd elixir && grep -rn "Tracker.adapter\|Tracker\\.Memory" test`

Record the file where `Tracker.adapter/0` is exercised.

- [ ] **Step 2: Add a failing test**

Append to that file (or create a new `test/symphony_elixir/tracker_test.exs` if none exists):

```elixir
test "Tracker.adapter/0 returns Jira.Adapter when kind is \"jira\"" do
  original = Application.get_env(:symphony_elixir, :workflow_config)

  on_exit(fn -> Application.put_env(:symphony_elixir, :workflow_config, original) end)

  Application.put_env(:symphony_elixir, :workflow_config, %{
    "tracker" => %{"kind" => "jira", "jira" => %{"site_url" => "https://a.atlassian.net", "email" => "e@x", "api_token" => "t", "project_key" => "A"}}
  })

  assert SymphonyElixir.Tracker.adapter() == SymphonyElixir.Jira.Adapter
end
```

If `tracker_test.exs` does not exist, create it with full scaffolding:

```elixir
defmodule SymphonyElixir.TrackerTest do
  use ExUnit.Case, async: false

  # (test body above)
end
```

- [ ] **Step 3: Run the test and confirm it fails**

Run: `cd elixir && mix test test/symphony_elixir/tracker_test.exs`

Expected: FAIL — `Tracker.adapter/0` returns `Linear.Adapter` for `"jira"`.

- [ ] **Step 4: Add the `"jira"` branch**

Edit `elixir/lib/symphony_elixir/tracker.ex`:

```elixir
  def adapter do
    case Config.settings!().tracker.kind do
      "memory" -> SymphonyElixir.Tracker.Memory
      "jira" -> SymphonyElixir.Jira.Adapter
      _ -> SymphonyElixir.Linear.Adapter
    end
  end
```

- [ ] **Step 5: Run tests**

Run: `cd elixir && mix test test/symphony_elixir/tracker_test.exs && mix test`

Expected: both the new test and the full suite pass.

- [ ] **Step 6: Format and commit**

```bash
cd elixir && mix format
cd .. && git add -A
git commit -m "feat(elixir): dispatch tracker.kind=\"jira\" to Jira.Adapter"
```

---

## Task 12: Documentation

Update `elixir/README.md` with the new nested config shape, a Jira example, and the new env vars.

**Files:**
- Modify: `elixir/README.md`

- [ ] **Step 1: Find the existing tracker docs**

Run: `cd elixir && grep -n "LINEAR_API_KEY\|tracker\|project_slug" README.md`

Record the section where tracker config is documented.

- [ ] **Step 2: Update that section**

Replace any flat-shape example (`tracker.api_key`, `tracker.project_slug`) with:

````markdown
### Tracker configuration

Symphony supports Linear and Jira Cloud as issue trackers, plus an in-memory
adapter for tests. Shared fields live on `tracker`; tracker-specific fields
live under `tracker.linear` or `tracker.jira`.

#### Linear

```yaml
tracker:
  kind: linear
  assignee: me
  active_states: [Todo, In Progress]
  linear:
    project_slug: acme-web
    endpoint: https://api.linear.app/graphql
    # api_key falls back to the LINEAR_API_KEY env var if omitted
```

Env vars: `LINEAR_API_KEY`, `LINEAR_ASSIGNEE`.

#### Jira Cloud

```yaml
tracker:
  kind: jira
  assignee: me                 # or a Jira accountId (usernames are deprecated)
  active_states: [To Do, In Progress]
  jira:
    site_url: https://acme.atlassian.net
    project_key: ABC
    # email and api_token fall back to JIRA_EMAIL / JIRA_API_TOKEN env vars
```

Env vars: `JIRA_API_TOKEN`, `JIRA_EMAIL`, `JIRA_ASSIGNEE`.

Notes on the Jira adapter:

- `branch_name` is derived as `jira/<key>-<slug(summary)>` — Jira has no
  native branch-name field.
- Descriptions and comments are transported as ADF (Atlassian Document
  Format), serialized to/from plain text.
- State transitions are resolved dynamically by querying the available
  transitions for an issue, so operators never supply transition IDs.
````

- [ ] **Step 3: Verify nothing else references the old shape**

Run: `cd elixir && grep -rn "tracker\.api_key\|tracker\\.endpoint\|tracker\\.project_slug" README.md docs lib test`

Expected: zero matches (all old references replaced).

- [ ] **Step 4: Commit**

```bash
git add elixir/README.md
git commit -m "docs(elixir): document Jira tracker config and nested tracker.*.<kind> shape"
```

---

## Task 13: Full-suite green + format check

Final sanity sweep.

- [ ] **Step 1: Run the entire suite**

Run: `cd elixir && mix test`

Expected: all tests pass.

- [ ] **Step 2: Run the format check**

Run: `cd elixir && mix format --check-formatted`

Expected: no output (exit 0).

- [ ] **Step 3: Compile with warnings-as-errors**

Run: `cd elixir && mix compile --warnings-as-errors`

Expected: clean compile.

- [ ] **Step 4: If any of the above failed, fix and recommit**

Fix iteratively. Each fix gets its own small commit (`fix(elixir): ...`).

- [ ] **Step 5: Final verification log line**

Run: `cd .. && git log --oneline origin/main..HEAD`

Expected: a clean sequence of the per-task commits above, in order. This is the final state to hand off or PR.
