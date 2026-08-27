defmodule Throttle.Workers.JobCleanerTest do
  use Throttle.DataCase

  alias Throttle.Repo
  alias Throttle.ActionQueries
  alias Throttle.Schemas.ActionExecution
  alias Throttle.Workers.JobCleaner

  test "starts only runnable queues" do
    portal_id = System.unique_integer([:positive])
    runnable = execution_attrs("queue:#{portal_id}:runnable")
    permanent = execution_attrs("queue:test:permanent") |> Map.put(:permanently_failed, true)

    held =
      execution_attrs("queue:test:held")
      |> Map.put(
        :on_hold_until,
        DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.truncate(:second)
      )

    assert {3, nil} = Repo.insert_all(ActionExecution, [runnable, permanent, held])

    assert :ok = JobCleaner.perform(%Oban.Job{})
    assert [{runner_pid, _}] = Registry.lookup(Throttle.QueueRunnerRegistry, runnable.queue_id)
    assert [] = Registry.lookup(Throttle.QueueRunnerRegistry, permanent.queue_id)
    assert [] = Registry.lookup(Throttle.QueueRunnerRegistry, held.queue_id)

    on_exit(fn ->
      if Process.alive?(runner_pid) do
        GenServer.stop(runner_pid, :normal)
      end

      case Registry.lookup(Throttle.PortalRegistry, portal_id) do
        [{portal_pid, _}] ->
          GenServer.stop(portal_pid, :normal)

        [] ->
          :ok
      end
    end)
  end

  test "ramps one missing runner per run and prioritizes the fastest drain" do
    fast_portal_id = System.unique_integer([:positive])
    slow_portal_id = System.unique_integer([:positive])

    fast =
      execution_attrs("queue:#{fast_portal_id}:fast")
      |> Map.merge(%{max_throughput: "100", time: "1", period: "seconds"})

    slow =
      execution_attrs("queue:#{slow_portal_id}:slow")
      |> Map.merge(%{max_throughput: "1", time: "1", period: "hours"})

    assert {2, nil} = Repo.insert_all(ActionExecution, [slow, fast])

    assert :ok = JobCleaner.perform(%Oban.Job{})
    assert [{fast_runner_pid, _}] = Registry.lookup(Throttle.QueueRunnerRegistry, fast.queue_id)
    assert [] = Registry.lookup(Throttle.QueueRunnerRegistry, slow.queue_id)

    on_exit(fn ->
      stop_runner(fast_runner_pid)
      stop_portal_queue(fast_portal_id)
      stop_portal_queue(slow_portal_id)
    end)
  end

  test "uses the latest rate once for a queue with mixed historical configurations" do
    portal_id = System.unique_integer([:positive])
    queue_id = "queue:#{portal_id}:mixed"
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    old =
      execution_attrs(queue_id)
      |> Map.merge(%{
        callback_id: "old-rate",
        max_throughput: "1",
        time: "1",
        period: "hours",
        inserted_at: now,
        updated_at: now
      })

    latest =
      execution_attrs(queue_id)
      |> Map.merge(%{
        callback_id: "latest-rate",
        max_throughput: "4",
        time: "2",
        period: "seconds",
        on_hold_until:
          DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.truncate(:second),
        inserted_at: NaiveDateTime.add(now, 1, :second),
        updated_at: NaiveDateTime.add(now, 1, :second)
      })

    assert {2, nil} = Repo.insert_all(ActionExecution, [old, latest])

    assert [%{max_throughput: "4", time: "2", period: "seconds"}] =
             ActionQueries.runnable_queue_configs()

    assert :ok = JobCleaner.recover_missing_queues(1)
    assert [{runner_pid, _}] = Registry.lookup(Throttle.QueueRunnerRegistry, queue_id)

    state = :sys.get_state(runner_pid)
    assert state.max_throughput == "4"
    assert state.time == "2"
    assert state.period == "seconds"
    assert state.delay_ms == 2_000

    newer =
      execution_attrs(queue_id)
      |> Map.merge(%{
        callback_id: "newest-rate",
        max_throughput: "2",
        time: "1",
        period: "minutes",
        inserted_at: NaiveDateTime.add(now, 2, :second),
        updated_at: NaiveDateTime.add(now, 2, :second)
      })

    assert {1, nil} = Repo.insert_all(ActionExecution, [newer])
    assert {:ok, ^runner_pid} = Throttle.QueueRunner.ensure_started(queue_id)

    updated_state = :sys.get_state(runner_pid)
    assert updated_state.max_throughput == "2"
    assert updated_state.delay_ms == 60_000

    assert :ok =
             GenServer.call(runner_pid, {
               :update_config,
               %{
                 config_id: state.config_id,
                 max_throughput: "99",
                 time: "1",
                 period: "seconds"
               }
             })

    state_after_stale_update = :sys.get_state(runner_pid)
    assert state_after_stale_update.config_id == updated_state.config_id
    assert state_after_stale_update.max_throughput == "2"
    assert state_after_stale_update.delay_ms == 60_000

    on_exit(fn ->
      stop_runner(runner_pid)
      stop_portal_queue(portal_id)
    end)
  end

  defp execution_attrs(queue_id) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    %{
      queue_id: queue_id,
      callback_id: "callback:#{queue_id}",
      processed: false,
      max_throughput: "3",
      time: "1",
      period: "seconds",
      last_failure_reason: nil,
      consecutive_failures: 0,
      on_hold_until: nil,
      total_attempts: 0,
      permanently_failed: false,
      inserted_at: now,
      updated_at: now
    }
  end

  defp stop_runner(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal)
    end
  end

  defp stop_portal_queue(portal_id) do
    case Registry.lookup(Throttle.PortalRegistry, portal_id) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end
  end
end
