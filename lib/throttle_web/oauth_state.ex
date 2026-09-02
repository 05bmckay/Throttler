defmodule ThrottleWeb.OAuthState do
  @moduledoc false

  import Plug.Conn, only: [delete_session: 2, fetch_session: 1, get_session: 2, put_session: 3]

  @session_key :hubspot_oauth_state
  @ttl_seconds 600

  def issue(conn) do
    conn = fetch_session(conn)
    state = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    issued_at = System.system_time(:second)

    {put_session(conn, @session_key, {state, issued_at}), state}
  end

  def consume(conn, state) when is_binary(state) do
    conn = fetch_session(conn)
    stored_state = get_session(conn, @session_key)
    conn = delete_session(conn, @session_key)

    case stored_state do
      {expected_state, issued_at}
      when is_binary(expected_state) and is_integer(issued_at) ->
        validate(conn, state, expected_state, issued_at)

      _other ->
        {:error, conn, "Invalid state parameter"}
    end
  end

  defp validate(conn, state, expected_state, issued_at) do
    age_seconds = System.system_time(:second) - issued_at

    cond do
      age_seconds < 0 or age_seconds > @ttl_seconds ->
        {:error, conn, "State parameter expired"}

      byte_size(state) != byte_size(expected_state) ->
        {:error, conn, "Invalid state parameter"}

      Plug.Crypto.secure_compare(state, expected_state) ->
        {:ok, conn}

      true ->
        {:error, conn, "Invalid state parameter"}
    end
  end
end
