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
end
