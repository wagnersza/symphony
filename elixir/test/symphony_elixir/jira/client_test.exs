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
end
