defmodule SymphonyElixir.ObservabilityPubSubTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixirWeb.ObservabilityPubSub

  test "subscribe and broadcast_update deliver dashboard updates" do
    assert :ok = ObservabilityPubSub.subscribe()
    assert :ok = ObservabilityPubSub.broadcast_update()
    assert_receive :observability_updated
  end

  test "broadcast_update is a no-op when pubsub is unavailable" do
    pubsub_child_id = Phoenix.PubSub.Supervisor

    on_exit(fn ->
      if Process.whereis(SymphonyElixir.PubSub) == nil do
        assert {:ok, _pid} =
                 Supervisor.restart_child(SymphonyElixir.Supervisor, pubsub_child_id)
      end
    end)

    assert is_pid(Process.whereis(SymphonyElixir.PubSub))
    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, pubsub_child_id)
    refute Process.whereis(SymphonyElixir.PubSub)

    assert :ok = ObservabilityPubSub.broadcast_update()
  end

  describe "per-issue events" do
    setup do
      # Issue IDs include characters like "HA-1"; test with the same shape.
      {:ok, issue_id: "HA-1"}
    end

    test "subscribe_issue/1 receives events broadcast to that issue", %{issue_id: id} do
      assert :ok = ObservabilityPubSub.subscribe_issue(id)

      event = %{seq: 1, summary: "hi", kind: :message, detail: %{text: "hi"}}
      assert :ok = ObservabilityPubSub.broadcast_issue_event(id, event)

      assert_receive {:timeline_event, ^event}
    end

    test "broadcast_issue_event/2 does not reach other issues' subscribers", %{issue_id: id} do
      :ok = ObservabilityPubSub.subscribe_issue(id)

      other_event = %{seq: 1, summary: "other", kind: :message, detail: %{text: "other"}}

      :ok =
        ObservabilityPubSub.broadcast_issue_event("OTHER-99", other_event)

      refute_receive {:timeline_event, ^other_event}, 100
    end
  end
end
