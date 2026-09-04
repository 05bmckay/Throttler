# Run only against a disposable local database:
# TEST_DATABASE_URL=ecto://USER@localhost/throttle_readiness_load MIX_ENV=test mix run scripts/readiness_load.exs
alias Throttle.{Repo, DispatchStore}
import Ecto.Query
url = System.fetch_env!("TEST_DATABASE_URL") |> URI.parse()
unless Mix.env() == :test and url.host in ["localhost", "127.0.0.1"] and
         String.starts_with?(url.path || "", "/throttle_readiness_") do
  raise "Load checks require MIX_ENV=test and a disposable local throttle_readiness_ database"
end
unless Repo.aggregate(Throttle.Schemas.ActionExecution, :count) == 0, do: raise("Load database must be empty")
count = String.to_integer(System.get_env("LOAD_ACTIONS") || "55000")
concurrency = String.to_integer(System.get_env("LOAD_CONCURRENCY") || "20")
portals = String.to_integer(System.get_env("LOAD_PORTALS") || "16")
stats = :ets.new(:readiness_stats, [:public, :set, write_concurrency: true])
:ets.insert(stats, {:queries, 0})
:telemetry.attach("readiness-query-count", [:throttle, :repo, :query],
  fn _, _, _, table -> :ets.update_counter(table, :queries, 1) end, stats)
commit = fn fun -> Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun) end
request = fn n ->
  body = Jason.encode!(%{callbackId: "load-#{n}", origin: %{portalId: 9_000_000 + rem(n, portals), actionDefinitionId: 903},
    context: %{workflowId: 902}, inputFields: %{maxThroughPut: "10000", time: "1", period: "seconds"}})
  ts = Integer.to_string(System.system_time(:millisecond))
  sig = :crypto.mac(:hmac, :sha256, "test-client-secret", "POSThttp://www.example.com/api/hubspot/action" <> body <> ts) |> Base.encode64()
  Plug.Test.conn(:post, "/api/hubspot/action", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("x-hubspot-request-timestamp", ts)
    |> Plug.Conn.put_req_header("x-hubspot-signature-v3", sig)
    |> ThrottleWeb.Endpoint.call(ThrottleWeb.Endpoint.init([]))
end
{elapsed_us, timings} = :timer.tc(fn ->
  1..count |> Task.async_stream(fn n -> commit.(fn ->
    {us, conn} = :timer.tc(fn -> request.(n) end)
    if conn.status != 200, do: raise("Admission returned #{conn.status}")
    us
  end) end, max_concurrency: concurrency, timeout: 60_000, ordered: false)
  |> Enum.map(fn {:ok, us} -> us end)
end)
[{_, admission_queries}] = :ets.lookup(stats, :queries)
rows = commit.(fn -> Repo.aggregate(Throttle.Schemas.ActionExecution, :count) end)
if rows != count, do: raise("Acknowledged action count differs from durable row count")
# Repeat already acknowledged requests without granting more rate or rows.
for n <- 1..100, do: commit.(fn -> if request.(n).status != 200, do: raise("Replay failed") end)
if commit.(fn -> Repo.aggregate(Throttle.Schemas.ActionExecution, :count) end) != count, do: raise("Replay created duplicate rows")
:ets.insert(stats, {:queries, 0})
{dispatch_us, batches} = :timer.tc(fn ->
  0..(portals-1) |> Task.async_stream(fn n -> commit.(fn ->
    drain = fn recurse, total ->
      case DispatchStore.claim(9_000_000+n) do
        {:ok, nil} ->
          pending = Repo.exists?(from a in Throttle.Schemas.ActionExecution,
            where: a.queue_id == ^"queue:#{9_000_000+n}:902:903:0" and not a.processed and not a.permanently_failed)
          if pending do
            Process.sleep(50)
            recurse.(recurse, total)
          else
            total
          end
        {:ok, batch} ->
          # Simulated successful HubSpot response; no production HTTP calls.
          {:ok, _} = DispatchStore.finish(batch, :ok)
          recurse.(recurse, total+1)
      end
    end
    drain.(drain, 0)
  end) end, max_concurrency: 16, timeout: 120_000) |> Enum.map(fn {:ok, n} -> n end) |> Enum.sum()
end)
processed = commit.(fn -> Repo.aggregate(from(a in Throttle.Schemas.ActionExecution, where: a.processed), :count) end)
if processed != count, do: raise("Dispatcher did not drain all admitted actions")
[{_, dispatch_queries}] = :ets.lookup(stats, :queries)
ordered = Enum.sort(timings)
result = %{actions: count, concurrency: concurrency, portals: portals, durable_rows: rows, processed: processed,
  admission_seconds: elapsed_us/1_000_000, admission_per_second: count*1_000_000/elapsed_us,
  admission_p50_ms: Enum.at(ordered, div(count,2))/1000,
  admission_p95_ms: Enum.at(ordered, trunc(count*0.95))/1000,
  admission_p99_ms: Enum.at(ordered, trunc(count*0.99))/1000,
  admission_queries: admission_queries, dispatch_seconds: dispatch_us/1_000_000,
  dispatch_batches: batches, dispatch_queries: dispatch_queries,
  delivery: "simulated 204; local database; no WAN latency", at: DateTime.to_iso8601(DateTime.utc_now())}
IO.puts(Jason.encode!(result, pretty: true))
if output = System.get_env("LOAD_REPORT_PATH"), do: File.write!(output, Jason.encode!(result, pretty: true) <> "\n")
