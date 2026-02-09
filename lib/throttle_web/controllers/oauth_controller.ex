defmodule ThrottleWeb.OAuthController do
  use ThrottleWeb, :controller
  alias Throttle.OAuthManager

  @hubspot_authorize_url "https://app.hubspot.com/oauth/authorize"
  @hubspot_token_url "https://api.hubapi.com/oauth/v1/token"
  @state_table :oauth_csrf_states
  @state_ttl_seconds 600

  def authorize(conn, _params) do
    ensure_table_exists()
    cleanup_stale_states()

    state = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    :ets.insert(@state_table, {state, System.system_time(:second)})

    query_params =
      URI.encode_query(%{
        client_id: Application.get_env(:throttle, :hubspot_client_id),
        redirect_uri: Routes.oauth_callback_url(conn, :callback),
        scope: "automation oauth",
        response_type: "code",
        state: state
      })

    authorize_url = "#{@hubspot_authorize_url}?#{query_params}"
    redirect(conn, external: authorize_url)
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    ensure_table_exists()

    case validate_state(state) do
      :ok ->
        do_token_exchange(conn, code)

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: reason})
    end
  end

  def callback(conn, %{"code" => _code}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing state parameter"})
  end

  def callback(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required parameters"})
  end

  defp do_token_exchange(conn, code) do
    case exchange_code_for_token(code, conn) do
      {:ok, token_data} ->
        case OAuthManager.store_token(token_data) do
          {:ok, _} ->
            json(conn, %{message: "Successfully authenticated with HubSpot"})

          {:error, reason} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Failed to store token: #{inspect(reason)}"})
        end

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Authentication failed: #{inspect(reason)}"})
    end
  end

  defp validate_state(state) do
    case :ets.lookup(@state_table, state) do
      [{^state, timestamp}] ->
        :ets.delete(@state_table, state)
        now = System.system_time(:second)

        if now - timestamp <= @state_ttl_seconds do
          :ok
        else
          {:error, "State parameter expired"}
        end

      [] ->
        {:error, "Invalid state parameter"}
    end
  end

  defp ensure_table_exists do
    case :ets.whereis(@state_table) do
      :undefined ->
        :ets.new(@state_table, [:set, :public, :named_table])

      _ref ->
        :ok
    end
  rescue
    ArgumentError ->
      # Table already created by a concurrent process
      :ok
  end

  defp cleanup_stale_states do
    cutoff = System.system_time(:second) - @state_ttl_seconds

    :ets.select_delete(@state_table, [
      {{:"$1", :"$2"}, [{:<, :"$2", cutoff}], [true]}
    ])
  end

  defp exchange_code_for_token(code, conn) do
    body =
      URI.encode_query(%{
        grant_type: "authorization_code",
        client_id: Application.get_env(:throttle, :hubspot_client_id),
        client_secret: Application.get_env(:throttle, :hubspot_client_secret),
        redirect_uri: Routes.oauth_callback_url(conn, :callback),
        code: code
      })

    headers = [{"Content-Type", "application/x-www-form-urlencoded"}]

    request = Finch.build(:post, @hubspot_token_url, headers, body)

    case Finch.request(request, Throttle.Finch, receive_timeout: 15_000, request_timeout: 30_000) do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        case Jason.decode(resp_body) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:error, "Failed to decode HubSpot token response"}
        end

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:error, "HubSpot API returned status code: #{status}, body: #{resp_body}"}

      {:error, exception} ->
        {:error, "HubSpot API request failed: #{Exception.message(exception)}"}
    end
  end
end
