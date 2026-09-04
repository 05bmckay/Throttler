defmodule ThrottleWeb.OAuthController do
  use ThrottleWeb, :controller
  alias Throttle.OAuthManager
  alias ThrottleWeb.OAuthState

  @hubspot_authorize_url "https://app.hubspot.com/oauth/authorize"
  @hubspot_token_url "https://api.hubapi.com/oauth/2026-03/token"

  def authorize(conn, _params) do
    {conn, state} = OAuthState.issue(conn)

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

    case Throttle.HTTP.request(request) do
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
