defmodule Throttle.Workers.JobCleaner do
  @moduledoc """
  Periodically scans for unprocessed actions and ensures an Oban worker job exists for each queue.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger
  import Ecto.Query

  alias Throttle.Repo
  alias Throttle.Schemas.ActionExecution
  alias Oban.Job

  # Run every 5 minutes
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("Running JobCleaner...")

    unprocessed_queue_ids = fetch_unprocessed_queue_ids()
    active_job_queue_ids = fetch_active_job_queue_ids()

    missing_queue_ids = MapSet.difference(unprocessed_queue_ids, active_job_queue_ids)
                      |> MapSet.to_list()

    if Enum.empty?(missing_queue_ids) do
      Logger.info("JobCleaner found no missing jobs.")
      :ok
    else
      Logger.info("JobCleaner found #{Enum.count(missing_queue_ids)} queues possibly missing jobs: #{inspect(missing_queue_ids)}")
      schedule_missing_jobs(missing_queue_ids)
    end
  end

  defp fetch_unprocessed_queue_ids do
    query = from(ae in ActionExecution,
      where: ae.processed == false,
      select: ae.queue_id,
      distinct: true
    )
    Repo.all(query) |> MapSet.new()
  end

  defp fetch_active_job_queue_ids do
    # States considered active: available, scheduled, executing
    # Note: Oban Pro adds `retrying` and `pending`, which could also be included.
    active_states = ["available", "scheduled", "executing"]

    query = from(j in Job,
      where: j.worker == ^to_string(Throttle.ThrottleWorker) and j.state in ^active_states,
      select: fragment("?->>'queue_id'", j.args),
      distinct: true
    )

    Repo.all(query)
    |> Enum.reject(&is_nil(&1)) # Filter out potential nil if args didn't have queue_id
    |> MapSet.new()
  end

  defp schedule_missing_jobs(queue_ids) do
    # Fetch one sample unprocessed action for each missing queue_id to get args
    # Using a subquery to get one distinct action per queue_id
    sub_query = from(ae in ActionExecution,
      where: ae.processed == false and ae.queue_id in ^queue_ids,
      distinct: ae.queue_id,
      select: %{
        queue_id: ae.queue_id,
        max_throughput: ae.max_throughput,
        time: ae.time,
        period: ae.period
      }
      # The distinct clause might not guarantee *which* action is picked if multiple
      # unprocessed actions exist for the same queue_id, but we assume the args
      # (max_throughput, time, period) are consistent per queue_id.
    )

    sample_actions = Repo.all(sub_query)

    Enum.each(sample_actions, fn action_args ->
      changeset = Throttle.ThrottleWorker.new(action_args)

      # Insert the job. The unique index handles conflicts if a job was
      # created between our check and this insert attempt.
      case Oban.insert(changeset, on_conflict: :nothing) do
        {:ok, job} ->
          Logger.info("JobCleaner scheduled missing job for queue #{action_args.queue_id}: #{inspect(job.id)}")
        {:error, _changeset_or_tuple} ->
          # This could be a conflict (which is OK and expected sometimes)
          # or a different error (which should be logged).
          # Oban.insert/2 returns {:error, changeset} on validation errors, or
          # {:error, {:conflict, message}} on conflicts with on_conflict: :nothing.
          # Log if it wasn't just a conflict (though conflict is hard to distinguish here reliably).
          Logger.warning("JobCleaner failed to insert job for queue #{action_args.queue_id} (possibly due to conflict or other error)")
      end
    end)

    :ok
  end
end
