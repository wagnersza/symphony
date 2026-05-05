defmodule SymphonyElixir.TrackerTest do
  use ExUnit.Case, async: false

  test "Tracker.adapter/0 returns Jira.Adapter when kind is \"jira\"" do
    original = Application.get_env(:symphony_elixir, :workflow_config)

    on_exit(fn -> Application.put_env(:symphony_elixir, :workflow_config, original) end)

    Application.put_env(:symphony_elixir, :workflow_config, %{
      "tracker" => %{"kind" => "jira", "jira" => %{"site_url" => "https://a.atlassian.net", "email" => "e@x", "api_token" => "t", "project_key" => "A"}}
    })

    assert SymphonyElixir.Tracker.adapter() == SymphonyElixir.Jira.Adapter
  end
end
