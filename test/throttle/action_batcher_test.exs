defmodule Throttle.ActionBatcherTest do
  use ExUnit.Case, async: true

  alias Throttle.ActionBatcher

  test "drops an admission request whose caller deadline has already expired" do
    state = %{
      buffer: [],
      buffer_size: 0,
      queues: %{},
      queued_size: 0,
      flush_interval: 5_000,
      timer_ref: nil,
      flushing: false,
      flush_task_ref: nil,
      pending_flush: []
    }

    expired_deadline = System.monotonic_time(:millisecond) - 1

    assert {:reply, {:error, :overloaded}, returned_state} =
             ActionBatcher.handle_call(
               {:add_action, %{callback_id: "expired-admission"}, expired_deadline},
               {self(), make_ref()},
               state
             )

    assert returned_state == state
  end
end
