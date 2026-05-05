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
