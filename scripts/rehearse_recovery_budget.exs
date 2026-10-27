# Synthetic local-only rehearsal of the additive delivery-budget migration.
alias Throttle.Repo

url = System.fetch_env!("TEST_DATABASE_URL") |> URI.parse()

unless Mix.env() == :test and url.host in ["localhost", "127.0.0.1"] and
         String.starts_with?(url.path || "", "/throttle_readiness_") do
  raise "Requires a disposable local throttle_readiness_ database"
end

Application.ensure_all_started(:ecto_sql)
Application.ensure_all_started(:postgrex)
{:ok, _} = Repo.start_link()

%{rows: [[nil]]} = Repo.query!("SELECT to_regclass('public.dispatch_queues')::text")
Ecto.Migrator.run(Repo, "priv/repo/migrations", :up, to: 20_260_908_152_000, log: false)

Repo.query!("INSERT INTO dispatch_portals (portal_id) VALUES (901)")

Repo.query!("""
INSERT INTO dispatch_queues
(queue_id, portal_id, max_throughput, interval_ms, next_run_at, budget_remaining, budget_through_id)
VALUES ('queue:901:902:903:0', 901, 15, 1000, timezone('UTC',now())+interval '1 day', 7, 1000),
       ('queue:901:904:903:0', 901, 1, 86400000, timezone('UTC',now())-interval '1 second', 0, 2000)
""")

snapshot = fn ->
  Repo.query!("""
  SELECT queue_id, max_throughput, interval_ms, next_run_at, budget_remaining, budget_through_id
  FROM dispatch_queues ORDER BY queue_id
  """).rows
end

before = snapshot.()

{duration, [20_261_027_190_000]} =
  :timer.tc(fn ->
    Ecto.Migrator.run(Repo, "priv/repo/migrations", :up, all: true, log: false)
  end)

^before = snapshot.()

%{rows: [[true]]} =
  Repo.query!("""
  SELECT bool_and(delivery_window_until=next_run_at AND delivery_count=max_throughput)
  FROM dispatch_queues
  """)

# Existing future allowance stays closed; a queue already due can recover.
%{rows: [[false], [true]]} =
  Repo.query!("""
  SELECT delivery_window_until <= timezone('UTC',now()) OR delivery_count < max_throughput
  FROM dispatch_queues ORDER BY queue_id
  """)

[] = Ecto.Migrator.run(Repo, "priv/repo/migrations", :up, all: true, log: false)
^before = snapshot.()

IO.puts(
  Jason.encode!(
    %{
      original_rate_and_reservations_preserved: true,
      no_extra_cutover_allowance: true,
      already_due_queue_can_recover: true,
      migration_rerun_is_noop: true,
      migration_seconds: duration / 1_000_000,
      data: "synthetic local fixtures; not production scale"
    },
    pretty: true
  )
)
