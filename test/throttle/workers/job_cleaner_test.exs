defmodule Throttle.Workers.JobCleanerTest do
  use Throttle.DataCase

  alias Throttle.Repo
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
        DynamicSupervisor.terminate_child(Throttle.QueueRunnerSupervisor, runner_pid)
      end

      case Registry.lookup(Throttle.PortalRegistry, portal_id) do
        [{portal_pid, _}] ->
          DynamicSupervisor.terminate_child(Throttle.PortalQueueSupervisor, portal_pid)

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
      DynamicSupervisor.terminate_child(Throttle.QueueRunnerSupervisor, pid)
    end
  end

  defp stop_portal_queue(portal_id) do
    case Registry.lookup(Throttle.PortalRegistry, portal_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(Throttle.PortalQueueSupervisor, pid)
      [] -> :ok
    end
  end
end
