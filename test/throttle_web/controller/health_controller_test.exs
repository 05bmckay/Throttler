defmodule ThrottleWeb.HealthControllerTest do
  use ThrottleWeb.ConnCase

  test "GET /api/health reports database readiness", %{conn: conn} do
    conn = get(conn, "/api/health")

    assert %{"status" => "ok"} = json_response(conn, 200)
  end
end
