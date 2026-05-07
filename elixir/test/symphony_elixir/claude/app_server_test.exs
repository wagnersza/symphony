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
               AppServer.start_session(System.tmp_dir!(),
                 Keyword.put(opts(), :worker_host, "some-host")
               )
    end
  end

  describe "run_turn/4" do
    test "streams normalized events to on_message and returns {:ok, session_summary}" do
      {:ok, session} = AppServer.start_session(System.tmp_dir!(), opts())
      me = self()

      issue = %{id: "HA-1", identifier: "HA-1", title: "fake"}

      assert {:ok, summary} =
               AppServer.run_turn(session, "hello", issue,
                 on_message: fn msg -> send(me, {:msg, msg}) end
               )

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
end
