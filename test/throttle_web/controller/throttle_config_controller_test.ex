defmodule ThrottleWeb.ThrottleConfigControllerTest do
  use ThrottleWeb.ConnCase

  alias Throttle.Schemas.ThrottleConfig

  @create_attrs %{
    portal_id: 42,
    action_id: "some-action",
    max_throughput: 100,
    time_period: 60,
    time_unit: "second"
  }
  @update_attrs %{
    max_throughput: 200,
    time_period: 120,
    time_unit: "minute"
  }
  @invalid_attrs %{
    portal_id: nil,
    action_id: nil,
    max_throughput: nil,
    time_period: nil,
    time_unit: nil
  }

  def fixture(:throttle_config) do
    {:ok, throttle_config} = Throttle.upsert_throttle_config(@create_attrs)
    throttle_config
  end

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "create throttle_config" do
    test "renders throttle_config when data is valid", %{conn: conn} do
      conn = post(conn, Routes.throttle_config_path(conn, :create), @create_attrs)
      assert %{"id" => id} = json_response(conn, 201)["data"]

      conn =
        get(
          conn,
          Routes.throttle_config_path(
            conn,
            :show,
            @create_attrs.portal_id,
            @create_attrs.action_id
          )
        )

      assert %{
               "id" => id,
               "action_id" => "some-action",
               "max_throughput" => 100,
               "portal_id" => 42,
               "time_period" => 60,
               "time_unit" => "second"
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn} do
      conn = post(conn, Routes.throttle_config_path(conn, :create), @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "update throttle_config" do
    setup [:create_throttle_config]

    test "renders throttle_config when data is valid", %{
      conn: conn,
      throttle_config: %ThrottleConfig{id: id} = throttle_config
    } do
      conn = put(conn, Routes.throttle_config_path(conn, :update, throttle_config), @update_attrs)
      assert %{"id" => ^id} = json_response(conn, 200)["data"]

      conn = get(conn, Routes.throttle_config_path(conn, :show, throttle_config))

      assert %{
               "id" => id,
               "action_id" => "some-action",
               "max_throughput" => 200,
               "portal_id" => 42,
               "time_period" => 120,
               "time_unit" => "minute"
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn, throttle_config: throttle_config} do
      conn =
        put(conn, Routes.throttle_config_path(conn, :update, throttle_config), @invalid_attrs)

      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  defp create_throttle_config(_) do
    throttle_config = fixture(:throttle_config)
    %{throttle_config: throttle_config}
  end
end
