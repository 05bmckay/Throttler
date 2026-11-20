defmodule ThrottleWeb.OAuthControllerTest do
  use ThrottleWeb.ConnCase, async: false

  alias Throttle.HTTPStub
  alias Throttle.OAuthManager

  setup do
    previous_uri = Application.get_env(:throttle, :hubspot_redirect_uri)
    previous_adapter = Application.get_env(:throttle, :http_adapter)
    Application.put_env(:throttle, :http_adapter, HTTPStub)

    on_exit(fn ->
      if is_nil(previous_adapter) do
        Application.delete_env(:throttle, :http_adapter)
      else
        Application.put_env(:throttle, :http_adapter, previous_adapter)
      end

      if is_nil(previous_uri) do
        Application.delete_env(:throttle, :hubspot_redirect_uri)
      else
        Application.put_env(:throttle, :hubspot_redirect_uri, previous_uri)
      end
    end)

    :ok
  end

  test "authorize uses configured :hubspot_redirect_uri when present", %{conn: conn} do
    configured_uri = "https://throttler-app.cartermckay.com/api/oauth/callback"
    Application.put_env(:throttle, :hubspot_redirect_uri, configured_uri)

    conn = get(conn, Routes.oauth_authorize_path(conn, :authorize))
    [location] = get_resp_header(conn, "location")
    params = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert params["redirect_uri"] == configured_uri
  end

  test "authorize falls back to endpoint callback URL when :hubspot_redirect_uri is unset", %{
    conn: conn
  } do
    Application.delete_env(:throttle, :hubspot_redirect_uri)

    conn = get(conn, Routes.oauth_authorize_path(conn, :authorize))
    [location] = get_resp_header(conn, "location")
    params = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert params["redirect_uri"] == Routes.oauth_callback_url(conn, :callback)
  end

  test "callback sends configured :hubspot_redirect_uri on token exchange and stores token", %{
    conn: conn
  } do
    configured_uri = "https://throttler-app.cartermckay.com/api/oauth/callback"
    Application.put_env(:throttle, :hubspot_redirect_uri, configured_uri)

    start_supervised!(%{
      id: HTTPStub,
      start:
        {HTTPStub, :start_link,
         [
           [
             HTTPStub.response(
               200,
               Jason.encode!(%{
                 "access_token" => "new-access-token",
                 "refresh_token" => "new-refresh-token",
                 "expires_in" => 1800
               })
             ),
             HTTPStub.response(
               200,
               Jason.encode!(%{"hub_id" => 99_421, "user" => "ops@example.com"})
             )
           ]
         ]}
    })

    auth_conn = get(conn, Routes.oauth_authorize_path(conn, :authorize))
    [location] = get_resp_header(auth_conn, "location")

    state =
      location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

    callback_conn =
      auth_conn
      |> recycle()
      |> get(Routes.oauth_callback_path(conn, :callback), %{
        "code" => "auth-code-123",
        "state" => state
      })

    assert %{"message" => "Successfully authenticated with HubSpot"} =
             json_response(callback_conn, 200)

    [token_req, info_req] = HTTPStub.requests()
    assert token_req.path == "/oauth/2026-03/token"
    form = URI.decode_query(token_req.body)
    assert form["redirect_uri"] == configured_uri
    assert form["code"] == "auth-code-123"
    assert info_req.path == "/oauth/2026-03/token/introspect"

    assert {:ok, stored} = OAuthManager.get_token(99_421)
    assert stored.access_token == "new-access-token"
  end

  test "callback does not leak upstream HubSpot error body in HTTP response", %{conn: conn} do
    start_supervised!(%{
      id: HTTPStub,
      start:
        {HTTPStub, :start_link,
         [[HTTPStub.response(400, ~s({"message":"secret upstream detail"}))]]}
    })

    auth_conn = get(conn, Routes.oauth_authorize_path(conn, :authorize))
    [location] = get_resp_header(auth_conn, "location")

    state =
      location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

    callback_conn =
      auth_conn
      |> recycle()
      |> get(Routes.oauth_callback_path(conn, :callback), %{
        "code" => "bad-code",
        "state" => state
      })

    assert %{"error" => "Authentication failed"} = json_response(callback_conn, 400)
    refute callback_conn.resp_body =~ "secret upstream detail"
  end
end
