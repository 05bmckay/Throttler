defmodule ThrottleWeb.OAuthStateTest do
  use ThrottleWeb.ConnCase, async: true

  alias ThrottleWeb.OAuthState

  test "the authorization state survives in the signed session cookie", %{conn: conn} do
    conn = get(conn, Routes.oauth_authorize_path(conn, :authorize))

    [location] = get_resp_header(conn, "location")

    state =
      location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

    assert byte_size(state) >= 43
    assert Map.has_key?(conn.resp_cookies, "_throttle_key")

    callback_conn =
      conn
      |> recycle()
      |> get(Routes.oauth_callback_path(conn, :callback), %{
        "code" => "unused-test-code",
        "state" => state <> "tampered"
      })

    assert %{"error" => "Invalid state parameter"} = json_response(callback_conn, 400)
  end

  test "a state value is single-use", %{conn: conn} do
    conn = init_test_session(conn, %{})
    {conn, state} = OAuthState.issue(conn)

    assert {:ok, conn} = OAuthState.consume(conn, state)
    assert {:error, _conn, "Invalid state parameter"} = OAuthState.consume(conn, state)
  end

  test "a mismatched state is rejected and consumed", %{conn: conn} do
    conn = init_test_session(conn, %{})
    {conn, state} = OAuthState.issue(conn)

    assert {:error, conn, "Invalid state parameter"} = OAuthState.consume(conn, state <> "x")
    assert {:error, _conn, "Invalid state parameter"} = OAuthState.consume(conn, state)
  end
end
