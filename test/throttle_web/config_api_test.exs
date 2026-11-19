defmodule ThrottleWeb.ConfigApiTest do
  use ThrottleWeb.ConnCase
  import Throttle.DispatchFixtures
  @key String.duplicate("config-test-", 4)

  setup do
    Application.put_env(:throttle, :config_api_key, @key)
    on_exit(fn -> Application.delete_env(:throttle, :config_api_key) end)
    :ok
  end

  test "config reads and writes require authentication", %{conn: conn} do
    assert get(conn, "/api/config/901/903").status == 401
    assert post(conn, "/api/config", %{}).status == 401
  end

  test "JSON writes update durable queue settings without resetting its budget", %{conn: conn} do
    admit("config-api")
    {:ok, batch} = Throttle.DispatchStore.claim(901)
    Throttle.DispatchStore.finish(batch, :ok)
    before = Throttle.Repo.query!("SELECT next_run_at FROM dispatch_queues").rows

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{@key}")
      |> post("/api/config", %{
        "portal_id" => 901,
        "action_id" => "903",
        "max_throughput" => 5,
        "time_period" => 1,
        "time_unit" => "days"
      })

    assert %{"max_throughput" => 5} = json_response(conn, 201)

    assert %{rows: [[5, 86_400_000]]} =
             Throttle.Repo.query!("SELECT max_throughput, interval_ms FROM dispatch_queues")

    assert before == Throttle.Repo.query!("SELECT next_run_at FROM dispatch_queues").rows
  end

  test "JSON writes shortening interval pull an active delivery window forward", %{conn: conn} do
    admit("config-api-shorten-1", %{max_throughput: "1", time: "1", period: "days"})
    admit("config-api-shorten-2", %{max_throughput: "1", time: "1", period: "days"})
    {:ok, batch} = Throttle.DispatchStore.claim(901)
    Throttle.DispatchStore.finish(batch, :ok)

    assert {:ok, nil} = Throttle.DispatchStore.claim(901)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{@key}")
      |> post("/api/config", %{
        "portal_id" => 901,
        "action_id" => "903",
        "max_throughput" => 1,
        "time_period" => 1,
        "time_unit" => "seconds"
      })

    assert %{"max_throughput" => 1, "time_unit" => "seconds"} = json_response(conn, 201)

    assert %{rows: [[1, 1_000, next_run_at, delivery_window_until]]} =
             Throttle.Repo.query!(
               "SELECT max_throughput, interval_ms, next_run_at, delivery_window_until FROM dispatch_queues"
             )

    assert next_run_at == delivery_window_until
    assert NaiveDateTime.diff(delivery_window_until, NaiveDateTime.utc_now(), :second) <= 2
  end

  test "invalid rates return validation errors", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer #{@key}")
      |> post("/api/config", %{
        "portal_id" => 901,
        "action_id" => "903",
        "max_throughput" => 0,
        "time_period" => 1,
        "time_unit" => "seconds"
      })

    assert %{"errors" => _} = json_response(conn, 422)
  end
end
