defmodule Throttle.Workers.JobCleaner do
  @moduledoc """
  Periodically scans for runnable actions and gradually restores missing QueueRunners.

  ThrottleWorker jobs are short-lived bootstrap jobs: they start a QueueRunner and
  then complete. Treating the absence of an active Oban job as a missing queue is
  therefore incorrect after the QueueRunner refactor.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger
  alias Throttle.ActionQueries

  # Run every 5 minutes
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("Running JobCleaner...")
    recover_missing_queues(recovery_queues_per_run())
  end

  def recover_missing_queues(limit) when is_integer(limit) and limit > 0 do
    {expired_count, _} = ActionQueries.expire_overdue_actions()

    if expired_count > 0 do
      Logger.warning("Marked #{expired_count} expired HubSpot BLOCK actions as terminal")
    end

    runnable_queues =
      ActionQueries.runnable_queue_configs()
      |> Enum.reject(&runner_active?(&1.queue_id))
      |> Enum.sort_by(&estimated_drain_seconds/1)
      |> Enum.take(limit)

    results =
      Enum.map(runnable_queues, fn config ->
        case Throttle.QueueRunner.ensure_started(config.queue_id) do
          {:ok, _pid} ->
            :ok

          {:error, reason} ->
            Logger.error(
              "JobCleaner failed to start runner for #{config.queue_id}: #{inspect(reason)}"
            )

            {:error, {config.queue_id, reason}}
        end
      end)

    failures = Enum.filter(results, &match?({:error, _}, &1))

    if failures == [] do
      Logger.info(
        "JobCleaner started #{length(runnable_queues)} missing queue runners (limit #{limit} per run)."
      )

      :ok
    else
      {:error, {:runner_start_failures, failures}}
    end
  end

  defp runner_active?(queue_id) do
    Registry.lookup(Throttle.QueueRunnerRegistry, queue_id) != []
  end

  defp recovery_queues_per_run do
    Application.get_env(:throttle, :recovery_queues_per_run, 1)
  end

  defp estimated_drain_seconds(config) do
    with {throughput, ""} when throughput > 0 <- Integer.parse(to_string(config.max_throughput)),
         {time, ""} when time > 0 <- Integer.parse(to_string(config.time)),
         period_seconds when is_integer(period_seconds) <- period_seconds(config.period) do
      config.backlog_size * time * period_seconds / throughput
    else
      _ -> :infinity
    end
  end

  defp period_seconds("seconds"), do: 1
  defp period_seconds("minutes"), do: 60
  defp period_seconds("hours"), do: 3_600
  defp period_seconds("days"), do: 86_400
  defp period_seconds(_), do: nil
end
