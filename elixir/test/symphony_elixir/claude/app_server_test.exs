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
end
