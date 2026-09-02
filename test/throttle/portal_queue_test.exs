defmodule Throttle.PortalQueueTest do
  use Throttle.DataCase

  alias Throttle.PortalQueue
  alias Throttle.Repo
  alias Throttle.Schemas.ActionExecution

  setup do
    portal_id = System.unique_integer([:positive])

    {:ok, pid} =
      DynamicSupervisor.start_child(
        Throttle.PortalQueueSupervisor,
        {PortalQueue, portal_id}
      )

    on_exit(fn ->
      if Process.alive?(pid) do
        DynamicSupervisor.terminate_child(Throttle.PortalQueueSupervisor, pid)
      end
    end)

    %{portal_id: portal_id, pid: pid}
  end

  test "delivers an idle queue immediately and schedules the remainder", %{
    portal_id: portal_id,
    pid: pid
  } do
    executions = insert_executions(portal_id, 150)
    first_batch_ids = executions |> Enum.take(100) |> Enum.map(& &1.id)

    PortalQueue.enqueue_executions(pid, executions, self())
    state = :sys.get_state(pid)

    assert :queue.len(state.queue) == 50
    assert is_reference(state.timer_ref)

    # No OAuth token exists for this portal, so delivery is attempted and
    # fails, which still acknowledges the batch to its owner.
    assert_receive {:portal_delivery_complete, completed_ids}
    assert Enum.sort(completed_ids) == Enum.sort(first_batch_ids)

    for id <- first_batch_ids do
      assert Repo.get!(ActionExecution, id).last_failure_reason == "token_error"
    end
  end

  test "rows that are no longer processable are acknowledged without delivery", %{
    portal_id: portal_id,
    pid: pid
  } do
    [processed, live] = insert_executions(portal_id, 2)

    Repo.update_all(from(a in ActionExecution, where: a.id == ^processed.id),
      set: [processed: true]
    )

    PortalQueue.enqueue_executions(pid, [processed, live], self())
    :sys.get_state(pid)

    assert_receive {:portal_delivery_complete, stale_ids}
    assert stale_ids == [processed.id]
    assert_receive {:portal_delivery_complete, live_ids}
    assert live_ids == [live.id]
    untouched = Repo.get!(ActionExecution, processed.id)
    assert untouched.last_failure_reason == "in_flight"
    assert untouched.total_attempts == 0
    assert Repo.get!(ActionExecution, live.id).last_failure_reason == "token_error"
  end

  defp insert_executions(portal_id, count) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      Enum.map(1..count, fn n ->
        %{
          queue_id: "queue:#{portal_id}:1:1:0",
          callback_id: "cb-#{portal_id}-#{n}",
          processed: false,
          max_throughput: "10",
          time: "1",
          period: "seconds",
          last_failure_reason: "in_flight",
          consecutive_failures: 0,
          total_attempts: 0,
          permanently_failed: false,
          inserted_at: now,
          updated_at: now
        }
      end)

    {^count, nil} = Repo.insert_all(ActionExecution, rows)

    Repo.all(
      from(a in ActionExecution, where: a.queue_id == ^"queue:#{portal_id}:1:1:0", order_by: a.id)
    )
  end
end
