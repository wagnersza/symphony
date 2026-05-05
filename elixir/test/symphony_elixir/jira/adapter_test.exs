defmodule SymphonyElixir.Jira.AdapterTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Jira.Adapter

  defmodule FakeClient do
    @moduledoc false

    def set_transitions(key, response), do: Agent.update(__MODULE__.Agent, &Map.put(&1, {:transitions, key}, response))
    def set_post_response(response), do: Agent.update(__MODULE__.Agent, &Map.put(&1, :post_response, response))
    def calls, do: Agent.get(__MODULE__.Agent, & &1)

    def start, do: Agent.start(fn -> %{} end, name: __MODULE__.Agent)
    def stop, do: Agent.stop(__MODULE__.Agent)

    def request(:get, "/issue/" <> rest, nil, _opts) do
      key = rest |> String.split("/") |> List.first()
      Agent.get(__MODULE__.Agent, &Map.get(&1, {:transitions, key}, {:error, :not_stubbed}))
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
      FakeClient.set_transitions(
        "ABC-1",
        {:ok,
         %{
           "transitions" => [],
           "fields" => %{"status" => %{"name" => "In Progress"}}
         }}
      )

      assert Adapter.update_issue_state("ABC-1", "In Progress") == :ok
      refute Map.has_key?(FakeClient.calls(), :last_post)
    end

    test "posts the transition when target differs and transition exists" do
      FakeClient.set_transitions(
        "ABC-1",
        {:ok,
         %{
           "transitions" => [%{"id" => "31", "to" => %{"name" => "Done"}}],
           "fields" => %{"status" => %{"name" => "In Progress"}}
         }}
      )

      FakeClient.set_post_response({:ok, %{}})

      assert Adapter.update_issue_state("ABC-1", "Done") == :ok

      {path, body} = Map.fetch!(FakeClient.calls(), :last_post)
      assert path == "/issue/ABC-1/transitions"
      assert body == %{"transition" => %{"id" => "31"}}
    end

    test "returns :state_not_found when no matching transition" do
      FakeClient.set_transitions(
        "ABC-1",
        {:ok,
         %{
           "transitions" => [%{"id" => "31", "to" => %{"name" => "Done"}}],
           "fields" => %{"status" => %{"name" => "In Progress"}}
         }}
      )

      assert Adapter.update_issue_state("ABC-1", "Blocked") == {:error, :state_not_found}
    end

    test "returns :issue_update_failed when transition POST fails" do
      FakeClient.set_transitions(
        "ABC-1",
        {:ok,
         %{
           "transitions" => [%{"id" => "31", "to" => %{"name" => "Done"}}],
           "fields" => %{"status" => %{"name" => "Todo"}}
         }}
      )

      FakeClient.set_post_response({:error, {:jira_api_status, 400}})

      assert Adapter.update_issue_state("ABC-1", "Done") == {:error, :issue_update_failed}
    end
  end
end
