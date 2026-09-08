# MIX_ENV=test TEST_DATABASE_URL=ecto://postgres@127.0.0.1:55436/throttle_readiness_incident \
# mix run --no-start scripts/rehearse_incident.exs
# Synthetic only: exercises the real scheduler/store while admissions contend.
alias Throttle.{Repo, Admission, Dispatcher}
url = System.fetch_env!("TEST_DATABASE_URL") |> URI.parse()

unless Mix.env() == :test and url.host in ["localhost", "127.0.0.1"] and
         String.starts_with?(url.path || "", "/throttle_readiness_") do
  raise "Requires a disposable local throttle_readiness_ database"
end

config = Application.fetch_env!(:throttle, Repo)

Application.put_env(
  :throttle,
  Repo,
  Keyword.merge(config, pool: DBConnection.ConnectionPool, log: false)
)

Application.put_env(:throttle, :dispatch_enabled, false)

defmodule Throttle.IncidentNoHTTP do
  def request(_, _, _), do: raise("HTTP is forbidden in incident rehearsal")
end

defmodule Throttle.IncidentDelivery do
  def run(batch) do
    if length(batch.actions) > 12, do: raise("Exceeded configured burst")
    owned = Throttle.DispatchStore.owned_actions(batch)
    if length(owned) != length(batch.actions), do: raise("Lost ownership before simulated send")
    {:ok, _} = Throttle.DispatchStore.finish(batch, :ok)
    send(Process.whereis(:incident_rehearsal), {:batch, batch.portal_id, length(owned)})
    :ok
  end
end

Application.put_env(:throttle, :http_adapter, Throttle.IncidentNoHTTP)
Application.ensure_all_started(:throttle)
Logger.configure(level: :warning)
Process.register(self(), :incident_rehearsal)
%{rows: [[0]]} = Repo.query!("SELECT count(*) FROM action_executions")

Repo.query!(
  """
  INSERT INTO action_executions (queue_id, callback_id, processed, max_throughput, time, period, inserted_at, updated_at)
  SELECT 'queue:9900000:902:903:0', 'history-'||n, true, '12','1','seconds',
  timezone('UTC',now())-interval '10 days',timezone('UTC',now())-interval '10 days'
  FROM generate_series(1,2000000) n
  """,
  [],
  timeout: 180_000
)

for portal <- 9_900_001..9_900_006 do
  attrs = %{
    queue_id: "queue:#{portal}:902:903:0",
    callback_id: "seed-#{portal}",
    max_throughput: "12",
    time: "1",
    period: "seconds",
    expires_at: Throttle.BlockExpiration.expires_at()
  }

  {:ok, _} = Admission.admit(attrs)

  Repo.query!(
    """
    INSERT INTO action_executions (queue_id,callback_id,processed,max_throughput,time,period,inserted_at,updated_at,expires_at)
    SELECT $1::text, $1::text||'-pending-'||n, false,'12','1','seconds',timezone('UTC',now()),timezone('UTC',now()),
      timezone('UTC',now())+interval '28 days' FROM generate_series(1,20000) n
    """,
    [attrs.queue_id],
    timeout: 60_000
  )
end

Repo.query!("ANALYZE action_executions", [], timeout: 60_000)

%{rows: [[plan]]} =
  Repo.query!(
    """
    EXPLAIN (ANALYZE,BUFFERS,TIMING OFF,FORMAT JSON)
    SELECT id FROM action_executions WHERE queue_id=$1 AND NOT processed AND NOT permanently_failed
      AND NOT rate_reserved AND (expires_at IS NULL OR expires_at>timezone('UTC',clock_timestamp()))
      AND (on_hold_until IS NULL OR on_hold_until<=timezone('UTC',clock_timestamp()))
    ORDER BY inserted_at,id LIMIT 12
    """,
    ["queue:9900001:902:903:0"]
  )

started = System.monotonic_time(:millisecond)
:sys.replace_state(Dispatcher, &%{&1 | enabled: true, delivery: Throttle.IncidentDelivery})

timings =
  1..2000
  |> Task.async_stream(
    fn n ->
      attrs = %{
        queue_id: "queue:9900001:902:903:0",
        callback_id: "burst-#{n}",
        max_throughput: "12",
        time: "1",
        period: "seconds",
        expires_at: Throttle.BlockExpiration.expires_at()
      }

      {us, {:ok, _}} = :timer.tc(fn -> Admission.admit(attrs) end)
      us
    end,
    max_concurrency: 20,
    timeout: 15_000
  )
  |> Enum.map(fn {:ok, us} -> us end)
  |> Enum.sort()

%{rows: [[2000]]} =
  Repo.query!("SELECT count(*) FROM action_executions WHERE callback_id LIKE 'burst-%'")

remaining = max(30_000 - (System.monotonic_time(:millisecond) - started), 0)
Process.sleep(remaining)
:sys.replace_state(Dispatcher, &%{&1 | enabled: false})

wait = fn recurse ->
  if Dispatcher.status().active_tasks > 0 do
    Process.sleep(25)
    recurse.(recurse)
  end
end

wait.(wait)

%{rows: completed} =
  Repo.query!("""
  SELECT queue_id,count(*) FROM action_executions WHERE completed_at IS NOT NULL GROUP BY queue_id ORDER BY queue_id
  """)

if length(completed) != 6, do: raise("A portal was starved")

if Enum.any?(completed, fn [_, n] -> n < 240 end),
  do: raise("Dispatcher failed to sustain 8/second per portal")

result = %{
  history_rows: 2_000_000,
  initial_pending: 120_006,
  concurrent_admissions: 2000,
  concurrency: 20,
  duration_ms: System.monotonic_time(:millisecond) - started,
  admission_p95_ms: Enum.at(timings, 1900) / 1000,
  admission_p99_ms: Enum.at(timings, 1980) / 1000,
  completed_by_queue: completed,
  query_plan: plan,
  delivery: "real dispatcher and database ownership; simulated success; HTTP forbidden"
}

output =
  System.get_env("INCIDENT_REPORT_PATH") || "docs/readiness/incident-rehearsal-results.json"

File.write!(output, Jason.encode!(result, pretty: true) <> "\n")
IO.puts(Jason.encode!(Map.delete(result, :query_plan), pretty: true))
