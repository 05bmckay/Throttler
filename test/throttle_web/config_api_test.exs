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
