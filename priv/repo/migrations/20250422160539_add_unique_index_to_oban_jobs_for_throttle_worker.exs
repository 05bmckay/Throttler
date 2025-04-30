defmodule Throttle.Repo.Migrations.AddUniqueIndexToObanJobsForThrottleWorker do
  use Ecto.Migration

  # Define the name of the index
  @index_name :oban_jobs_throttle_worker_queue_id_unique_index

  def change do
    # Create a unique index on worker and the 'queue_id' value within the JSONB args,
    # but only for jobs where the worker is 'Throttle.ThrottleWorker'.
    create unique_index(
      :oban_jobs,
      [:worker, fragment("(args->>'queue_id')")],
      name: @index_name,
      where: "worker = 'Throttle.ThrottleWorker'"
    )
  end
end
