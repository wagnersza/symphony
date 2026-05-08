defmodule SymphonyElixir.Claude.AppServerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Claude.AppServer

  @fake_wrapper Path.expand("../../support/fake_claude_wrapper.sh", __DIR__)

  defp opts(extra \\ %{}) do
    [
      executable: "bash",
      args: [@fake_wrapper],
      env: Map.merge(%{"FAKE_WRAPPER_MODE" => "happy_path"}, extra) |> Enum.to_list()
    ]
  end

  describe "start_session/2" do
    test "returns {:ok, session} after ready" do
      assert {:ok, %{port: port}} =
               AppServer.start_session(System.tmp_dir!(), opts())

      assert is_port(port)

      assert :ok = AppServer.stop_session(%{port: port})
    end

    test "returns {:error, {:wrapper_startup_failed, _, _}} when wrapper exits before ready" do
      assert {:error, {:wrapper_startup_failed, _exit, _tail}} =
               AppServer.start_session(
                 System.tmp_dir!(),
                 opts(%{"FAKE_WRAPPER_MODE" => "startup_fail"})
               )
    end

    test "returns {:error, {:unsupported_worker_host, _}} when worker_host is non-nil" do
      assert {:error, {:unsupported_worker_host, "some-host"}} =
               AppServer.start_session(
                 System.tmp_dir!(),
                 Keyword.put(opts(), :worker_host, "some-host")
               )
    end

    test "stores :issue_id and :issue_identifier on the session map when provided" do
      assert {:ok, session} =
               AppServer.start_session(
                 System.tmp_dir!(),
                 Keyword.merge(opts(), issue_id: "HA-42", issue_identifier: "HA-42")
               )

      assert session.issue_id == "HA-42"
      assert session.issue_identifier == "HA-42"

      :ok = AppServer.stop_session(session)
    end

    test "defaults :issue_id and :issue_identifier to nil when not provided" do
      assert {:ok, session} = AppServer.start_session(System.tmp_dir!(), opts())
      assert session.issue_id == nil
      assert session.issue_identifier == nil

      :ok = AppServer.stop_session(session)
    end
  end

  describe "run_turn/4" do
    test "streams normalized events to on_message and returns {:ok, session_summary}" do
      {:ok, session} = AppServer.start_session(System.tmp_dir!(), opts())
      me = self()

      issue = %{id: "HA-1", identifier: "HA-1", title: "fake"}

      assert {:ok, summary} =
               AppServer.run_turn(session, "hello", issue, on_message: fn msg -> send(me, {:msg, msg}) end)

      # Event order must match what EventNormalizer expects (string event names).
      assert_receive {:msg, %{event: "turn_start"}}, 1_500
      assert_receive {:msg, %{event: "tool_call", tool: "Read"}}, 1_500
      assert_receive {:msg, %{event: "tool_result", tool: "Read", ok: true}}, 1_500
      assert_receive {:msg, %{event: "message", text: "done"}}, 1_500
      assert_receive {:msg, %{event: "tokens", input: 10, output: 5, total: 15}}, 1_500
      assert_receive {:msg, %{event: "turn_end"}}, 1_500

      assert %{session_id: "sess_fake_1"} = summary

      :ok = AppServer.stop_session(session)
    end
  end

  describe "integration with EventNormalizer" do
    test "every emitted message normalizes to a non-:ignore shape" do
      alias SymphonyElixir.Observability.EventNormalizer

      {:ok, session} = AppServer.start_session(System.tmp_dir!(), opts())
      me = self()
      issue = %{id: "HA-1", identifier: "HA-1", title: "fake"}

      {:ok, _} =
        AppServer.run_turn(session, "hello", issue, on_message: fn msg -> send(me, {:msg, msg}) end)

      AppServer.stop_session(session)

      # Drain mailbox and verify each is normalizable.
      msgs = drain_messages()
      refute msgs == []

      normalized = Enum.map(msgs, &EventNormalizer.normalize/1)

      # turn_start, tool_call, tool_result, message, tokens, turn_end — 6 events.
      # All should normalize to maps (none :ignore).
      assert Enum.all?(normalized, &is_map/1),
             "expected all events to normalize, got: #{inspect(normalized)}"

      kinds = Enum.map(normalized, & &1.kind) |> Enum.sort()
      assert :tool_call in kinds
      assert :tool_result in kinds
      assert :message in kinds
      assert :tokens in kinds
      assert :turn in kinds
    end

    defp drain_messages(acc \\ []) do
      receive do
        {:msg, m} -> drain_messages([m | acc])
      after
        100 -> Enum.reverse(acc)
      end
    end
  end
end
