# Restore an explicitly approved backup into an isolated local database first.
# MIX_ENV=test TEST_DATABASE_URL=ecto://postgres@localhost:55449/throttle_readiness_restored \
#   mix run --no-start scripts/rehearse_restore.exs
# Starts only Repo; never starts the application, OAuth, Oban, or delivery tasks.
alias Throttle.Repo

url = System.fetch_env!("TEST_DATABASE_URL") |> URI.parse()

unless Mix.env() == :test and url.host in ["localhost", "127.0.0.1"] and
         url.path == "/throttle_readiness_restored" do
  raise "Requires the isolated local throttle_readiness_restored database"
end

unless Process.whereis(Throttle.Supervisor) == nil,
  do: raise("Run with --no-start; application must not be running")

Application.ensure_all_started(:ecto_sql)
Application.ensure_all_started(:postgrex)

Application.put_env(
  :throttle,
  Repo,
  Application.fetch_env!(:throttle, Repo) |> Keyword.put(:pool, DBConnection.ConnectionPool)
)

{:ok, _} = Repo.start_link()
query = fn sql -> Repo.query!(sql, [], timeout: :infinity).rows end
[[nil]] = query.("SELECT to_regclass('public.dispatch_queues')::text")

[[before_bytes, wal_start]] =
  query.("SELECT pg_database_size(current_database()), pg_current_wal_lsn()::text")

[[before_rows, before_pending]] =
  query.(
    "SELECT count(*), count(*) FILTER (WHERE NOT processed AND NOT permanently_failed) FROM action_executions"
  )

[[expected_rows, expected_pending]] =
  query.("""
  SELECT count(*), count(*) FILTER (WHERE NOT processed AND NOT permanently_failed)
  FROM (SELECT DISTINCT ON (callback_id) callback_id, processed, permanently_failed
    FROM action_executions ORDER BY callback_id, processed DESC, permanently_failed ASC, id ASC) retained
  """)

[[credentials_before]] =
  query.(
    "SELECT count(*) FROM oauth_tokens WHERE token_response ?| ARRAY['access_token','refresh_token','token','client_secret']"
  )

[[started_at]] = query.("SELECT timezone('UTC',clock_timestamp())")

{duration, versions} =
  :timer.tc(fn ->
    Ecto.Migrator.run(Repo, "priv/repo/migrations", :up, all: true, log: false)
  end)

[^expected_rows, ^expected_pending] =
  query.(
    "SELECT count(*), count(*) FILTER (WHERE NOT processed AND NOT permanently_failed) FROM action_executions"
  )
  |> hd()

[[0]] =
  query.(
    "SELECT count(*) FROM oauth_tokens WHERE token_response ?| ARRAY['access_token','refresh_token','token','client_secret']"
  )

[[0]] =
  query.(
    "SELECT count(*) FROM action_executions a LEFT JOIN dispatch_queues q USING(queue_id) WHERE NOT a.processed AND NOT a.permanently_failed AND q.queue_id IS NULL"
  )

[[0]] =
  query.(
    "SELECT count(*) FROM oban_jobs WHERE worker='Throttle.ThrottleWorker' AND state IN ('available','scheduled','executing','retryable')"
  )

[[true]] =
  query.(
    "SELECT indisvalid AND indisunique FROM pg_index WHERE indexrelid='action_executions_callback_id_index'::regclass"
  )

[[0]] =
  Repo.query!(
    "SELECT count(*) FROM dispatch_queues WHERE next_run_at < $1::timestamp + interval_ms * interval '1 millisecond'",
    [started_at]
  ).rows

[[after_bytes, wal_bytes]] =
  Repo.query!(
    "SELECT pg_database_size(current_database()), pg_wal_lsn_diff(pg_current_wal_lsn(), $1::text::pg_lsn)::bigint",
    [wal_start]
  ).rows

# Let the statistics collector publish the migration's temporary-file totals.
query.("SELECT pg_stat_clear_snapshot()")

[[temp_bytes]] =
  query.("SELECT temp_bytes FROM pg_stat_database WHERE datname=current_database()")

[] = Ecto.Migrator.run(Repo, "priv/repo/migrations", :up, all: true, log: false)

result = %{
  scope:
    "Actual Render logical export restored into isolated local PostgreSQL 16; no application or callback workers started; local timing is not a Render guarantee",
  before_rows: before_rows,
  before_pending: before_pending,
  after_rows: expected_rows,
  after_pending: expected_pending,
  duplicate_rows_removed: before_rows - expected_rows,
  credential_metadata_rows_scrubbed: credentials_before,
  migration_seconds: duration / 1_000_000,
  versions_applied: versions,
  before_database_bytes: before_bytes,
  after_database_bytes: after_bytes,
  migration_wal_bytes: wal_bytes,
  cumulative_temp_bytes: temp_bytes,
  unique_callback_index_valid: true,
  all_active_work_has_queue: true,
  legacy_worker_jobs_cancelled: true,
  full_initial_cooldown: true,
  rerun_noop: true
}

File.write!("docs/readiness/restore-results.json", Jason.encode!(result, pretty: true) <> "\n")
IO.puts(Jason.encode!(result, pretty: true))
