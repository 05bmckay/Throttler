defmodule Throttle.AdmissionTest do
  use Throttle.DataCase
  import Throttle.DispatchFixtures
  alias Throttle.{Admission, Repo}
  alias Throttle.Schemas.ActionExecution

  test "success is durable and replay keeps one action and original deadline" do
    first = admit("durable")
    assert Repo.get!(ActionExecution, first.id).callback_id == "durable"

    {:ok, replay} =
      Admission.admit(attrs("durable", %{expires_at: DateTime.add(first.expires_at, 300)}))

    assert replay.id == first.id
    assert replay.expires_at == first.expires_at
    assert Repo.aggregate(ActionExecution, :count) == 1
  end

  test "completed callback replay never creates fresh work" do
    first = admit("complete")
    Repo.update_all(ActionExecution, set: [processed: true])
    {:ok, replay} = Admission.admit(attrs("complete"))
    assert replay.id == first.id and replay.processed
  end

  test "duplicate old payload cannot revert the current queue configuration" do
    admit("old", %{max_throughput: "1"})
    admit("new", %{max_throughput: "7"})
    admit("old", %{max_throughput: "1"})
    assert %{rows: [[7]]} = Repo.query!("SELECT max_throughput FROM dispatch_queues")
  end

  test "callback identity cannot move queues" do
    admit("identity")

    assert {:error, :callback_conflict} =
             Admission.admit(attrs("identity", %{queue_id: "queue:902:903:904:0"}))
  end

  test "invalid and unbounded rates fail before insertion" do
    for overrides <- [
          %{max_throughput: "0"},
          %{max_throughput: "10001"},
          %{time: "29", period: "days"},
          %{period: "fortnights"},
          %{callback_id: 123}
        ] do
      assert {:error, _} = Admission.admit(attrs("invalid", overrides))
    end

    assert Repo.aggregate(ActionExecution, :count) == 0
  end

  test "shortening interval_ms adjusts active window without staying frozen for the old interval" do
    admit("long-1", %{max_throughput: "1", time: "7", period: "days"})
    {:ok, first} = Throttle.DispatchStore.claim(901)
    assert {:ok, _} = Throttle.DispatchStore.finish(first, :ok)

    # Simulate 2 seconds elapsed since window opened under a 7-day interval.
    Repo.query!(
      "UPDATE dispatch_queues SET delivery_window_until = delivery_window_until - interval '2 seconds', next_run_at = next_run_at - interval '2 seconds'"
    )

    admit("short-2", %{max_throughput: "1", time: "1", period: "seconds"})

    # Elapsed 2s > new 1s interval, so the queue is immediately eligible again.
    assert {:ok, second} = Throttle.DispatchStore.claim(901)
    assert hd(second.actions).callback_id == "short-2"
  end

  test "queue write failure rolls back callback admission" do
    Repo.query!(
      "ALTER TABLE dispatch_queues ADD CONSTRAINT audit_reject_queue CHECK (portal_id != 901)"
    )

    assert {:error, :unavailable} = Admission.admit(attrs("rollback"))
    assert Repo.get_by(ActionExecution, callback_id: "rollback") == nil
  end
end
