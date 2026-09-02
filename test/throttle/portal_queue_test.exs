defmodule Throttle.PortalQueueTest do
  use Throttle.DataCase

  alias Throttle.PortalQueue
  alias Throttle.Schemas.ActionExecution

  test "schedules another flush when more than one HTTP batch is queued" do
    portal_id = System.unique_integer([:positive])

    assert {:ok, pid} =
             DynamicSupervisor.start_child(
               Throttle.PortalQueueSupervisor,
               {PortalQueue, portal_id}
             )

    on_exit(fn ->
      if Process.alive?(pid) do
        DynamicSupervisor.terminate_child(Throttle.PortalQueueSupervisor, pid)
      end
    end)

    executions =
      Enum.map(1..150, fn id ->
        %ActionExecution{id: id, queue_id: "queue:#{portal_id}:1:1:0", callback_id: "cb-#{id}"}
      end)

    PortalQueue.enqueue_executions(portal_id, executions, self())
    state = :sys.get_state(pid)

    assert :queue.len(state.queue) == 50
    assert is_reference(state.timer_ref)
    assert_receive {:portal_delivery_complete, completed_ids}
    assert Enum.sort(completed_ids) == Enum.to_list(1..100)
  end
end
