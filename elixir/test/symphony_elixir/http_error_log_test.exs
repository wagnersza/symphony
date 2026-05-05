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
