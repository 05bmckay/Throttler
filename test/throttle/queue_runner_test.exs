defmodule Throttle.QueueRunnerTest do
  use ExUnit.Case, async: true

  alias Throttle.QueueRunner

  test "does not claim another batch while portal delivery is outstanding" do
    state = %{
      queue_id: "queue:1:2:3:0",
      config_id: 1,
      max_throughput: "12",
      time: "1",
      period: "seconds",
      delay_ms: 60_000,
      timer_ref: nil,
      in_flight: %{101 => System.monotonic_time(:millisecond)},
      portal_pid: nil,
      portal_monitor_ref: nil,
      idle_since: nil
    }

    assert {:noreply, waiting_state} = QueueRunner.handle_info(:tick, state)
    assert waiting_state.in_flight == state.in_flight
    assert is_reference(waiting_state.timer_ref)
    Process.cancel_timer(waiting_state.timer_ref)

    assert {:noreply, acknowledged_state} =
             QueueRunner.handle_info({:portal_delivery_complete, [101]}, waiting_state)

    assert acknowledged_state.in_flight == %{}
    assert is_reference(acknowledged_state.timer_ref)
    Process.cancel_timer(acknowledged_state.timer_ref)
  end
end
