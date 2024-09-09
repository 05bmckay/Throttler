defmodule Throttle.OAuthManager do
  alias Throttle.{Repo, Schemas.SecureOAuthToken, Encryption}
  require Logger
  # import Ecto.Query

  @moduledoc """
  The OAuthManager module handles OAuth token management, including
  retrieval, refreshing, and storage of tokens.
  """

  @hubspot_base_url "https://api.hubapi.com"

  def store_token(token_data) do
    case fetch_token_details(token_data["access_token"]) do
      {:ok, token_details} ->
        %SecureOAuthToken{}
        |> SecureOAuthToken.changeset(%{
          portal_id: token_details["hub_id"],
          access_token: token_data["access_token"],
          refresh_token: token_data["refresh_token"],
          expires_at: calculate_expiration(token_data["expires_in"])
        })
        |> Repo.insert(on_conflict: :replace_all, conflict_target: :portal_id)

      error ->
        error
    end
  end

  # defp update_token(token, new_token_data) do
  #   token
  #   |> SecureOAuthToken.changeset(%{
  #     access_token: new_token_data["access_token"],
  #     refresh_token: new_token_data["refresh_token"],
  #     expires_at: calculate_expiration(new_token_data["expires_in"])
  #   })
  #   |> Repo.update()
  # end

  defp fetch_token_details(access_token) do
    url = "#{@hubspot_base_url}/oauth/v1/access-tokens/#{access_token}"
    headers = [{"Authorization", "Bearer #{access_token}"}]

    case HTTPoison.get(url, headers) do
      {:ok, %HTTPoison.Response{status_code: 200, body: resp_body}} ->
        {:ok, Jason.decode!(resp_body)}

      {:ok, %HTTPoison.Response{status_code: status_code, body: resp_body}} ->
        {:error, "Failed to fetch token details. Status code: #{status_code}, body: #{resp_body}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, "Failed to fetch token details: #{reason}"}
    end
  end

  @hubspot_oauth_url "https://api.hubapi.com/oauth/v1/token"

  def get_token(portal_id) do
      Logger.info(fn -> "Getting token for portal: #{portal_id}" end)
      case Repo.get_by(SecureOAuthToken, portal_id: portal_id) do
        nil ->
          Logger.warning(fn -> "Token not found for portal: #{portal_id}" end)
          {:error, :token_not_found}
        token ->
          Logger.info(fn -> "Token found for portal: #{portal_id}" end)
          decrypted_token = decrypt_token(token)
          if token_expired?(decrypted_token) do
            Logger.info(fn -> "Token expired for portal: #{portal_id}, refreshing" end)
            refresh_token(decrypted_token)
          else
            Logger.info(fn -> "Token valid for portal: #{portal_id}" end)
            {:ok, decrypted_token}
          end
      end
    end

    def refresh_token(token) do
      Logger.info(fn -> "Refreshing token for portal: #{token.portal_id}" end)
      case do_refresh_token(token) do
        {:ok, new_token_data} ->
          Logger.info(fn -> "Token refreshed successfully for portal: #{token.portal_id}" end)
          new_decrypted_token = %{token |
            access_token: new_token_data["access_token"],
            refresh_token: new_token_data["refresh_token"],
            expires_at: calculate_expiration(new_token_data["expires_in"])
          }
          case update_token(new_decrypted_token) do
            {:ok, _} ->
              Logger.info(fn -> "Token updated in database for portal: #{token.portal_id}" end)
              {:ok, new_decrypted_token}
            {:error, reason} ->
              Logger.error(fn -> "Failed to update token in database for portal #{token.portal_id}: #{inspect(reason)}" end)
              {:error, reason}
          end
        error ->
          Logger.error(fn -> "Failed to refresh token for portal #{token.portal_id}: #{inspect(error)}" end)
          error
      end
    end

    defp update_token(decrypted_token) do
      encrypted_token = encrypt_token(decrypted_token)
      encrypted_token
      |> SecureOAuthToken.changeset(%{
        access_token: encrypted_token.access_token,
        refresh_token: encrypted_token.refresh_token,
        expires_at: decrypted_token.expires_at
      })
      |> Repo.update()
    end

    defp encrypt_token(token) do
      %{token |
        access_token: Encryption.encrypt(token.access_token),
        refresh_token: Encryption.encrypt(token.refresh_token)
      }
    end

    defp decrypt_token(token) do
      %{token |
        access_token: Encryption.decrypt(token.access_token),
        refresh_token: Encryption.decrypt(token.refresh_token)
      }
    end

    def token_expired?(token) do
      is_expired = DateTime.compare(token.expires_at, DateTime.utc_now()) == :lt
      Logger.info(fn -> "Token expiration check for portal #{token.portal_id}: #{is_expired}" end)
      is_expired
    end

  defp do_refresh_token(token) do
    body =
      URI.encode_query(%{
        grant_type: "refresh_token",
        client_id: hubspot_client_id(),
        client_secret: hubspot_client_secret(),
        refresh_token: token.refresh_token
      })

    headers = [{"Content-Type", "application/x-www-form-urlencoded"}]

    case HTTPoison.post(@hubspot_oauth_url, body, headers) do
      {:ok, %HTTPoison.Response{status_code: 200, body: resp_body}} ->
        {:ok, Jason.decode!(resp_body)}

      {:ok, %HTTPoison.Response{status_code: status_code, body: resp_body}} ->
        {:error, "HubSpot API returned status code: #{status_code}, body: #{resp_body}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, "HubSpot API request failed: #{reason}"}
    end
  end

  defp calculate_expiration(expires_in) do
    DateTime.add(DateTime.utc_now(), expires_in, :second)
  end

  defp hubspot_client_id do
    Application.get_env(:throttle, :hubspot_client_id) ||
      raise "HubSpot Client ID not set. Please set the HUBSPOT_CLIENT_ID environment variable."
  end

  defp hubspot_client_secret do
    Application.get_env(:throttle, :hubspot_client_secret) ||
      raise "HubSpot Client Secret not set. Please set the HUBSPOT_CLIENT_SECRET environment variable."
  end
end
