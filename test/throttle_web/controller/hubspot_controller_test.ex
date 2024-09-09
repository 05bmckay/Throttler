defmodule ThrottleWeb.HubSpotControllerTest do
  use ThrottleWeb.ConnCase

  alias Throttle.Schemas.ThrottleConfig

  @create_attrs %{
    portal_id: 42,
    action_id: "some-action",
    max_throughput: 100,
    time_period: 60,
    time_unit: "second"
  }

  def fixture(:throttle_config) do
    {:ok, throttle_config} = Throttle.upsert_throttle_config(@create_attrs)
    throttle_config
  end

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "handle action" do
    test "responds with block when action is received", %{conn: conn} do
      throttle_config = fixture(:throttle_config)

      conn =
        post(conn, Routes.hub_spot_path(conn, :handle_action), %{
          "portalId" => throttle_config.portal_id,
          "actionId" => throttle_config.action_id,
          "callbackId" => "some-callback"
        })

      assert json_response(conn, 200)["outputFields"]["hs_execution_state"] == "BLOCK"
    end
  end
end
