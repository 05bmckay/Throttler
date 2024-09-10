defmodule ThrottleWeb.OAuthController do
  use ThrottleWeb, :controller
  alias Throttle.OAuthManager

  @hubspot_authorize_url "https://app.hubspot.com/oauth/authorize"
  @hubspot_token_url "https://api.hubapi.com/oauth/v1/token"

  def authorize(conn, _params) do
    query_params = URI.encode_query(%{
      client_id: Application.get_env(:throttle, :hubspot_client_id),
      redirect_uri: Routes.oauth_callback_url(conn, :callback),
      scope: "automation oauth",  # Adjust scopes as needed
      response_type: "code"
    })

    authorize_url = "#{@hubspot_authorize_url}?#{query_params}"
    redirect(conn, external: authorize_url)
  end

  def callback(conn, %{"code" => code}) do
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
    body = URI.encode_query(%{
      grant_type: "authorization_code",
      client_id: Application.get_env(:throttle, :hubspot_client_id),
      client_secret: Application.get_env(:throttle, :hubspot_client_secret),
      redirect_uri: Routes.oauth_callback_url(conn, :callback),
      code: code
    })

    headers = [{"Content-Type", "application/x-www-form-urlencoded"}]

    case HTTPoison.post(@hubspot_token_url, body, headers) do
      {:ok, %HTTPoison.Response{status_code: 200, body: resp_body}} ->
        {:ok, Jason.decode!(resp_body)}
      {:ok, %HTTPoison.Response{status_code: status_code, body: resp_body}} ->
        {:error, "HubSpot API returned status code: #{status_code}, body: #{resp_body}"}
      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, "HubSpot API request failed: #{reason}"}
    end
  end
end
