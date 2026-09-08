alias Throttle.Repo
url = System.fetch_env!("TEST_DATABASE_URL") |> URI.parse()

unless Mix.env() == :test and url.host == "127.0.0.1" and
         url.path == "/throttle_readiness_incident", do: raise("isolated rehearsal only")

Application.ensure_all_started(:ecto_sql)
Application.ensure_all_started(:postgrex)
{:ok, _} = Repo.start_link()

Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
  snapshot = fn ->
    Repo.query!("SELECT count(*),count(*) FILTER(WHERE NOT processed) FROM action_executions").rows
  end

  before = snapshot.()

  queues =
    Repo.query!(
      "SELECT queue_id,max_throughput,interval_ms,next_run_at,budget_remaining,budget_through_id FROM dispatch_queues ORDER BY queue_id"
    ).rows

  Repo.query!("DROP INDEX action_executions_pending_dispatch_index")
  Repo.query!("DELETE FROM schema_migrations WHERE version=20260908152000")

  {us, [20_260_908_152_000]} =
    :timer.tc(fn ->
      Ecto.Migrator.run(Repo, "priv/repo/migrations", :up, all: true, log: false)
    end)

  true = before == snapshot.()

  true =
    queues ==
      Repo.query!(
        "SELECT queue_id,max_throughput,interval_ms,next_run_at,budget_remaining,budget_through_id FROM dispatch_queues ORDER BY queue_id"
      ).rows

  %{rows: [[true]]} =
    Repo.query!(
      "SELECT indisvalid AND indisready FROM pg_index WHERE indexrelid='action_executions_pending_dispatch_index'::regclass"
    )

  [] = Ecto.Migrator.run(Repo, "priv/repo/migrations", :up, all: true, log: false)

  result = %{
    migration_seconds: us / 1_000_000,
    counts: before,
    counts_and_schedules_preserved: true,
    valid_index: true,
    second_run_no_op: true
  }

  File.write!(
    "docs/readiness/incident-index-rehearsal-results.json",
    Jason.encode!(result, pretty: true) <> "\n"
  )

  IO.puts(Jason.encode!(result, pretty: true))
end)
