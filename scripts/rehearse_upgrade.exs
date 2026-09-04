# Run with MIX_ENV=test mix run --no-start against a fresh local
# TEST_DATABASE_URL=ecto://USER@localhost/throttle_readiness_upgrade database.
alias Throttle.Repo
url = System.fetch_env!("TEST_DATABASE_URL") |> URI.parse()
unless Mix.env() == :test and url.host in ["localhost", "127.0.0.1"] and
       String.starts_with?(url.path || "", "/throttle_readiness_") do
  raise "Upgrade rehearsal requires a disposable local throttle_readiness_ database"
end
Application.ensure_all_started(:ecto_sql)
Application.ensure_all_started(:postgrex)
{:ok, _} = Repo.start_link()
Ecto.Migrator.run(Repo, "priv/repo/migrations", :up, to: 20260902150000, log: false)
Repo.query!("""
INSERT INTO action_executions
(queue_id, callback_id, processed, max_throughput, time, period, inserted_at, updated_at, expires_at)
VALUES ('queue:901:902:903:0','duplicate-done',false,'1','1','days',timezone('UTC',now()),timezone('UTC',now()),timezone('UTC',now())+interval '28 days'),
('queue:901:902:903:0','duplicate-done',true,'1','1','days',timezone('UTC',now()),timezone('UTC',now()),timezone('UTC',now())+interval '28 days'),
('queue:901:902:903:0','pending',false,'2','1','days',timezone('UTC',now()),timezone('UTC',now()),timezone('UTC',now())+interval '28 days'),
('queue:901:902:903:0','newest-config',true,'7','1','days',timezone('UTC',now()),timezone('UTC',now()),timezone('UTC',now())+interval '28 days')
""")
Repo.query!("""
INSERT INTO oauth_tokens (portal_id, access_token, refresh_token, expires_at, token_response, inserted_at, updated_at)
VALUES (901, 'fake-encrypted-access', 'fake-encrypted-refresh', timezone('UTC',now()),
'{"hub_id":901,"access_token":"fake-access","refresh_token":"fake-refresh","extra":{"secret":"fake"}}',
timezone('UTC',now()),timezone('UTC',now()))
""")
{duration, _} = :timer.tc(fn -> Ecto.Migrator.run(Repo, "priv/repo/migrations", :up, all: true, log: false) end)
%{rows: [[3, 1]]} = Repo.query!("SELECT count(*), count(*) FILTER (WHERE NOT processed) FROM action_executions")
%{rows: [[true]]} = Repo.query!("SELECT processed FROM action_executions WHERE callback_id='duplicate-done'")
%{rows: [[7, true]]} = Repo.query!("SELECT max_throughput, next_run_at > timezone('UTC',clock_timestamp()) + interval '23 hours' FROM dispatch_queues")
%{rows: [[false, false, false, true]]} = Repo.query!("SELECT token_response ? 'access_token', token_response ? 'refresh_token', token_response ? 'extra', token_response ? 'hub_id' FROM oauth_tokens")
assertions = %{unique_callbacks: true, completed_duplicate_wins: true, active_work_preserved: true,
  latest_historical_config: true, conservative_daily_cooldown: true, metadata_secrets_removed: true,
  migration_seconds: duration/1_000_000, data: "synthetic local fixtures; not production scale"}
# Rerun is a no-op, not a second cooldown reset or token rewrite.
[] = Ecto.Migrator.run(Repo, "priv/repo/migrations", :up, all: true, log: false)
IO.puts(Jason.encode!(assertions, pretty: true))
File.write!("docs/readiness/upgrade-results.json", Jason.encode!(assertions, pretty: true) <> "\n")
