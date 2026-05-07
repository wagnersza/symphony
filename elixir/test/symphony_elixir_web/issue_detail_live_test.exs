defmodule SymphonyElixirWeb.IssueDetailLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SymphonyElixirWeb.Endpoint

  alias SymphonyElixirWeb.ObservabilityPubSub

  defp start_test_endpoint(overrides \\ []) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "shows 'no active session' banner when issue is not running" do
    # With no Orchestrator running, issue_snapshot returns :unavailable or
    # :not_running — both should render the banner.
    start_test_endpoint()
    {:ok, _view, html} = live(build_conn(), "/issues/HA-404")
    assert html =~ "No active session"
    assert html =~ "HA-404"
  end

  test "appends events received on the per-issue topic" do
    # Spawn a tiny fake that claims to be the orchestrator's snapshot source
    # via PubSub, then broadcast a timeline event and assert render.
    start_test_endpoint()
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
end
