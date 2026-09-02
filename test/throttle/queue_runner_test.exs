defmodule Throttle.QueueRunnerTest do
  use Throttle.DataCase

  alias Throttle.QueueRunner

  @lease_ms :timer.seconds(Throttle.ActionQueries.claim_lease_seconds())

  defp state(overrides) do
    Map.merge(
      %{
        queue_id: "queue:1:2:3:0",
        config_id: 1,
        max_throughput: "12",
        time: "1",
        period: "seconds",
        delay_ms: 60_000,
        timer_ref: nil,
        tick_seq: 1,
        in_flight: %{},
        in_flight_since: nil,
        lease_guard_until: nil,
        portal_pid: nil,
        portal_monitor_ref: nil,
        idle_since: nil
      },
      overrides
    )
  end

  defp cancel(state), do: Process.cancel_timer(state.timer_ref)

  test "does not claim another batch while portal delivery is outstanding" do
    now = System.monotonic_time(:millisecond)
    state = state(%{in_flight: %{101 => now}, in_flight_since: now})

    assert {:noreply, waiting_state} = QueueRunner.handle_info({:tick, 1}, state)
    assert waiting_state.in_flight == state.in_flight
    assert is_reference(waiting_state.timer_ref)
    cancel(waiting_state)

    assert {:noreply, acknowledged_state} =
             QueueRunner.handle_info({:portal_delivery_complete, [101]}, waiting_state)

    assert acknowledged_state.in_flight == %{}
    assert acknowledged_state.in_flight_since == nil
    assert is_reference(acknowledged_state.timer_ref)
    cancel(acknowledged_state)
  end

  test "delivery completion supersedes the tick that was already armed" do
    now = System.monotonic_time(:millisecond)
    state = state(%{in_flight: %{101 => now}, in_flight_since: now})

    assert {:noreply, waiting_state} = QueueRunner.handle_info({:tick, 1}, state)

    assert {:noreply, acknowledged_state} =
             QueueRunner.handle_info({:portal_delivery_complete, [101]}, waiting_state)

    assert acknowledged_state.tick_seq > waiting_state.tick_seq
    cancel(acknowledged_state)

    # A tick armed before the reschedule is ignored instead of claiming.
    assert {:noreply, same_state} =
             QueueRunner.handle_info({:tick, waiting_state.tick_seq}, acknowledged_state)

    assert same_state == acknowledged_state
  end

  test "an outstanding batch older than the lease no longer blocks claiming" do
    now = System.monotonic_time(:millisecond)
    stale = now - @lease_ms - 1
    state = state(%{in_flight: %{101 => stale}, in_flight_since: stale})

    assert {:noreply, released_state} = QueueRunner.handle_info({:tick, 1}, state)
    assert released_state.in_flight == %{}
    assert released_state.in_flight_since == nil
    cancel(released_state)
  end

  test "stays alive through the lease window after a claim even when idle" do
    now = System.monotonic_time(:millisecond)
    guarded = state(%{idle_since: now - 60_000, lease_guard_until: now + @lease_ms})

    assert {:noreply, guarded_state} = QueueRunner.handle_info({:tick, 1}, guarded)
    cancel(guarded_state)

    expired = state(%{idle_since: now - 60_000, lease_guard_until: now - 1})
    assert {:stop, :normal, _state} = QueueRunner.handle_info({:tick, 1}, expired)
  end

  test "a superseded tick is dropped without side effects" do
    state = state(%{tick_seq: 5})
    assert {:noreply, ^state} = QueueRunner.handle_info({:tick, 4}, state)
  end
end
