defmodule ThrottleWeb.OAuthController do
  use ThrottleWeb, :controller
  require Logger
  alias Throttle.OAuthManager
  alias ThrottleWeb.OAuthState

  @hubspot_authorize_url "https://app.hubspot.com/oauth/authorize"
  @hubspot_token_url "https://api.hubapi.com/oauth/2026-03/token"

  def authorize(conn, _params) do
    {conn, state} = OAuthState.issue(conn)

    query_params =
      URI.encode_query(%{
        client_id: Application.get_env(:throttle, :hubspot_client_id),
        redirect_uri: redirect_uri(conn),
        scope: "automation oauth",
        response_type: "code",
        state: state
      })

    authorize_url = "#{@hubspot_authorize_url}?#{query_params}"
    redirect(conn, external: authorize_url)
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    case OAuthState.consume(conn, state) do
      {:ok, conn} ->
        do_token_exchange(conn, code)

      {:error, conn, reason} ->
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

          {:error, _reason} ->
            Logger.error("Failed to store HubSpot OAuth token during callback")

            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Failed to store token"})
        end

      {:error, reason} ->
        Logger.warning("HubSpot OAuth token exchange failed: #{reason}")

        conn
        |> put_status(:bad_request)
        |> json(%{error: "Authentication failed"})
    end
  end

  defp exchange_code_for_token(code, conn) do
    body =
      URI.encode_query(%{
        grant_type: "authorization_code",
        client_id: Application.get_env(:throttle, :hubspot_client_id),
        client_secret: Application.get_env(:throttle, :hubspot_client_secret),
        redirect_uri: redirect_uri(conn),
        code: code
      })

    headers = [{"Content-Type", "application/x-www-form-urlencoded"}]

    request = Finch.build(:post, @hubspot_token_url, headers, body)

    case Throttle.HTTP.request(request) do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        case Jason.decode(resp_body) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
          _ -> {:error, "invalid token response"}
        end

      {:ok, %Finch.Response{status: status}} ->
        {:error, "status #{status}"}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  defp redirect_uri(conn) do
    case Application.get_env(:throttle, :hubspot_redirect_uri) do
      uri when is_binary(uri) and uri != "" -> uri
      _ -> Routes.oauth_callback_url(conn, :callback)
    end
  end
end
