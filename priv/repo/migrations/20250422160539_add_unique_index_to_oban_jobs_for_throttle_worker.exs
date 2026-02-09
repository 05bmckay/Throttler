defmodule Throttle.Repo.Migrations.AddUniqueIndexToObanJobsForThrottleWorker do
  use Ecto.Migration

  @index_name "oban_jobs_throttle_worker_queue_id_unique_index"

  def up do
    # Remove duplicate ThrottleWorker jobs, keeping the one with the lowest id per queue_id
    execute("""
    DELETE FROM oban_jobs
    WHERE id IN (
      SELECT id FROM (
        SELECT id, ROW_NUMBER() OVER (
          PARTITION BY args->>'queue_id'
          ORDER BY id ASC
        ) AS rn
        FROM oban_jobs
        WHERE worker = 'Throttle.ThrottleWorker'
      ) dupes
      WHERE dupes.rn > 1
    )
    """)

    execute("""
    CREATE UNIQUE INDEX #{@index_name}
    ON oban_jobs (worker, (args->>'queue_id'))
    WHERE worker = 'Throttle.ThrottleWorker'
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS #{@index_name}")
  end
end
