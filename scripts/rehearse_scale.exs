# Synthetic historical-table migration rehearsal, never a production database.
alias Throttle.Repo
url = System.fetch_env!("TEST_DATABASE_URL") |> URI.parse()
unless Mix.env() == :test and url.host in ["localhost", "127.0.0.1"] and
       String.starts_with?(url.path || "", "/throttle_readiness_") do
  raise "Requires a disposable local throttle_readiness_ database"
end
Application.ensure_all_started(:ecto_sql)
Application.ensure_all_started(:postgrex)
Application.put_env(:throttle, Repo, Application.fetch_env!(:throttle, Repo) |> Keyword.put(:pool, DBConnection.ConnectionPool))
{:ok, _} = Repo.start_link()
Ecto.Migrator.run(Repo, "priv/repo/migrations", :up, to: 20260902150000, log: false)
%{rows: [[existing]]} = Repo.query!("SELECT count(*) FROM action_executions")
count = 7_600_000
IO.puts("Seeding #{count} synthetic historical actions")
if existing == 0 do
Repo.query!("""
INSERT INTO action_executions
(queue_id,callback_id,processed,max_throughput,time,period,inserted_at,updated_at,expires_at)
SELECT 'queue:' || (901 + n % 100) || ':902:' || (903 + n % 1000) || ':0',
 'scale-' || md5(n::text) || '-' || md5(('callback-' || n)::text), n > 42,
 '25','1','days', timezone('UTC',now())-interval '10 days',
 timezone('UTC',now())-interval '10 days',timezone('UTC',now())+interval '18 days'
FROM generate_series(1,$1) n
""", [count], timeout: :infinity)
else
  unless existing == count and System.get_env("SCALE_RESUME") == "true", do: raise("Scale database must be empty or an explicitly resumed fixture")
end
# Extra historical indexes model write/storage amplification. The exact live
# out-of-band schema must still be rehearsed from a sanitized production restore.
for {name, columns} <- [queue: "queue_id", callback: "callback_id", inserted: "inserted_at",
                       processed: "processed", queue_processed: "queue_id, processed", terminal: "permanently_failed, inserted_at"] do
  Repo.query!("CREATE INDEX IF NOT EXISTS scale_#{name}_idx ON action_executions (#{columns})", [], timeout: :infinity)
end
Repo.query!("ANALYZE action_executions", [], timeout: :infinity)
%{rows: [[before_bytes]]} = Repo.query!("SELECT pg_database_size(current_database())")
%{rows: [[wal_start]]} = Repo.query!("SELECT pg_current_wal_lsn()::text")
IO.puts("Migrating #{count} actions; starting database bytes #{before_bytes}")
{duration, _} = :timer.tc(fn -> Ecto.Migrator.run(Repo, "priv/repo/migrations", :up, all: true, log: false) end)
IO.puts("Migration finished in #{duration / 1_000_000} seconds")
%{rows: [[^count, 42]]} = Repo.query!("SELECT count(*), count(*) FILTER (WHERE NOT processed) FROM action_executions", [], timeout: :infinity)
%{rows: [[after_bytes, wal_bytes]]} = Repo.query!("SELECT pg_database_size(current_database()), pg_wal_lsn_diff(pg_current_wal_lsn(), $1::text::pg_lsn)::bigint", [wal_start])
%{rows: [[temp_bytes]]} = Repo.query!("SELECT temp_bytes FROM pg_stat_database WHERE datname=current_database()")
result = %{rows: count, pending_preserved: 42, migration_seconds: duration/1_000_000,
  before_database_bytes: before_bytes, after_database_bytes: after_bytes,
  migration_wal_bytes: wal_bytes, cumulative_temp_bytes: temp_bytes,
  scope: "local PostgreSQL 15; synthetic data and ten pre-cutover indexes; not a production timing guarantee"}
File.write!("docs/readiness/scale-results.json", Jason.encode!(result, pretty: true) <> "\n")
IO.puts(Jason.encode!(result, pretty: true))
