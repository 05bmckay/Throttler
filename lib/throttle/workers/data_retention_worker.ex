defmodule Throttle.Workers.DataRetentionWorker do
  @moduledoc """
  Periodically deletes old processed action_executions to prevent unbounded table growth.
  Runs daily via Oban cron, deleting records older than 30 days where processed = true.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger
  import Ecto.Query

  alias Throttle.Repo
  alias Throttle.Schemas.ActionExecution

  @batch_size 1000
  @retention_days 30

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("Running DataRetentionWorker...")

    total_deleted = delete_old_records(0)

    Logger.info("DataRetentionWorker completed. Total records deleted: #{total_deleted}")
    :ok
  end

  defp delete_old_records(total_deleted) do
    cutoff_date = DateTime.utc_now() |> DateTime.add(-@retention_days * 86400, :second)

    subquery =
      from(ae in ActionExecution,
        where: ae.processed == true and ae.inserted_at < ^cutoff_date,
        select: ae.id,
        limit: @batch_size
      )

    {deleted_count, _} =
      from(ae in ActionExecution,
        where: ae.id in subquery(subquery)
      )
      |> Repo.delete_all()

    new_total = total_deleted + deleted_count

    if deleted_count == @batch_size do
      delete_old_records(new_total)
    else
      new_total
    end
  end
end
