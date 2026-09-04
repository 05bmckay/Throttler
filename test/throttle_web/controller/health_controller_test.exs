defmodule ThrottleWeb.HealthControllerTest do
  use ThrottleWeb.ConnCase

  setup do
    :sys.replace_state(Throttle.Dispatcher, &%{&1 | enabled: true})
    on_exit(fn -> :sys.replace_state(Throttle.Dispatcher, &%{&1 | enabled: false}) end)
    :ok
  end

  test "GET /api/health reports database readiness", %{conn: conn} do
    conn = get(conn, "/api/health")

    assert %{"status" => "ok"} = json_response(conn, 200)
  end

  test "GET / supports Render's default root health probe", %{conn: conn} do
    conn = get(conn, "/")

    assert %{"status" => "ok"} = json_response(conn, 200)
  end

  test "paused dispatch fails readiness", %{conn: conn} do
    :sys.replace_state(Throttle.Dispatcher, &%{&1 | enabled: false})
    assert %{"status" => "unavailable"} = conn |> get("/api/health") |> json_response(503)
    assert %{"status" => "alive"} = conn |> get("/api/live") |> json_response(200)
  end
end
