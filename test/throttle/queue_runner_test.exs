defmodule Throttle.QueueRunnerTest do
  # Old tick-chain/lifecycle coverage is retained as scheduler-slot and durable
  # recovery coverage; per-queue timers no longer exist.
  use Throttle.DataCase
  import Throttle.DispatchFixtures
  alias Throttle.{Dispatcher, DispatchStore}

  defp state do
    {:ok, state} = Dispatcher.init([])
    Process.cancel_timer(state.timer)
    state
  end

  test "late logger overload replies leave delivery slots and watchdogs unchanged" do
    ref = make_ref()
    timer = Process.send_after(self(), :unused, 60_000)
    on_exit(fn -> Process.cancel_timer(timer) end)
    state = %{state() | enabled: true, tasks: %{ref => %{pid: self(), timer: timer}}}

    assert {:noreply, ^state} = Dispatcher.handle_info({[:alias | ref], :dropped}, state)
    assert Process.read_timer(timer) != false
    refute_receive :drain
  end

  test "a running dispatcher survives repeated late logger replies and keeps polling" do
    pid =
      start_supervised!(%{
        id: :logger_reply_dispatcher,
        start: {GenServer, :start_link, [Dispatcher, []]},
        restart: :temporary
      })

    before = :sys.get_state(pid)
    Process.cancel_timer(before.timer)

    for _ <- 1..10, do: send(pid, {[:alias | make_ref()], :dropped})
    send(pid, :poll)

    # This call is ordered after the injected messages and poll, and targets
    # the original PID so a supervisor restart cannot hide the crash.
    assert %{enabled: false, active_tasks: 0} = GenServer.call(pid, :status)
    after_poll = :sys.get_state(pid)
    assert after_poll.tasks == before.tasks
    assert is_reference(after_poll.timer)
    assert after_poll.timer != before.timer
    assert Process.read_timer(after_poll.timer) != false
  end

  test "delivery completion frees exactly one slot and stale messages are ignored" do
    ref = make_ref()
    timer = Process.send_after(self(), :unused, 60_000)
    state = %{state() | tasks: %{ref => %{pid: self(), timer: timer}}}
    assert {:noreply, finished} = Dispatcher.handle_info({ref, :ok}, state)
    assert finished.tasks == %{}
    assert {:noreply, ^finished} = Dispatcher.handle_info({ref, :ok}, finished)
  end

  test "crashed delivery frees local capacity without releasing its database lease" do
    admit("crashed")
    {:ok, batch} = DispatchStore.claim(901)
    ref = make_ref()
    timer = Process.send_after(self(), :unused, 60_000)
    state = %{state() | tasks: %{ref => %{pid: self(), timer: timer}}}

    assert {:noreply, finished} =
             Dispatcher.handle_info({:DOWN, ref, :process, self(), :killed}, state)

    assert finished.tasks == %{}
    assert DispatchStore.owned_actions(batch) != []
    assert {:ok, nil} = DispatchStore.claim(901)
  end

  test "expired claims recover after the owning task disappears" do
    admit("recover")
    {:ok, old} = DispatchStore.claim(901)

    Throttle.Repo.query!(
      "UPDATE dispatch_portals SET lease_until=timezone('UTC', now())-interval '1 second'"
    )

    Throttle.Repo.update_all(Throttle.Schemas.ActionExecution,
      set: [on_hold_until: DateTime.add(DateTime.utc_now(), -1)]
    )

    assert {:ok, replacement} = DispatchStore.claim(901)
    assert replacement.token != old.token
    assert {:error, :stale_claim} = DispatchStore.finish(old, :ok)
  end

  test "watchdog terminates the exact task and waits for DOWN before freeing its slot" do
    task =
      Task.Supervisor.async_nolink(Throttle.DeliverySupervisor, fn ->
        receive do
          :never -> :ok
        end
      end)

    timer = Process.send_after(self(), :unused, 60_000)
    state = %{state() | tasks: %{task.ref => %{pid: task.pid, timer: timer}}}
    assert {:noreply, ^state} = Dispatcher.handle_info({:task_timeout, task.ref}, state)
    ref = task.ref
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}
    refute Process.alive?(task.pid)
    Process.cancel_timer(timer)
  end

  test "a paused poll schedules one replacement timer without claiming work" do
    admit("paused")
    assert {:noreply, next} = Dispatcher.handle_info(:poll, state())
    assert next.tasks == %{}
    assert is_reference(next.timer)
    Process.cancel_timer(next.timer)
    assert {:ok, batch} = DispatchStore.claim(901)
    assert batch != nil
  end
end
