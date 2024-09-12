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
    Logger.info("Attempting to store token")
    case fetch_token_details(token_data["access_token"]) do
      {:ok, token_details} ->
        Logger.info("Successfully fetched token details: #{inspect(token_details)}")
        %SecureOAuthToken{}
        |> SecureOAuthToken.changeset(%{
          portal_id: token_details["hub_id"],
          access_token: token_data["access_token"],
          refresh_token: token_data["refresh_token"],
          expires_at: calculate_expiration(token_data["expires_in"])
        })
        |> Repo.insert(on_conflict: :replace_all, conflict_target: :portal_id)
        |> case do
          {:ok, token} ->
            Logger.info("Token stored successfully for portal_id: #{token.portal_id}")
            {:ok, token}
          {:error, changeset} ->
            Logger.error("Failed to store token: #{inspect(changeset.errors)}")
            {:error, changeset}
        end

      error ->
        Logger.error("Failed to fetch token details: #{inspect(error)}")
        error
    end
  end

  defp fetch_token_details(access_token) do
    Logger.info("Fetching token details from HubSpot")
    url = "#{@hubspot_base_url}/oauth/v1/access-tokens/#{access_token}"
    headers = [{"Authorization", "Bearer #{access_token}"}]

    case HTTPoison.get(url, headers) do
      {:ok, %HTTPoison.Response{status_code: 200, body: resp_body}} ->
        Logger.info("Successfully fetched token details")
        {:ok, Jason.decode!(resp_body)}

      {:ok, %HTTPoison.Response{status_code: status_code, body: resp_body}} ->
        Logger.error("Failed to fetch token details. Status code: #{status_code}, body: #{resp_body}")
        {:error, "Failed to fetch token details. Status code: #{status_code}, body: #{resp_body}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("HTTP request failed when fetching token details: #{reason}")
        {:error, "Failed to fetch token details: #{reason}"}
    end
  end

  @hubspot_oauth_url "https://api.hubapi.com/oauth/v1/token"

  def get_token(portal_id) do
    Logger.info("Getting token for portal: #{portal_id}")
    case Repo.get_by(SecureOAuthToken, portal_id: portal_id) do
      nil ->
        Logger.warning("Token not found for portal: #{portal_id}")
        {:error, :token_not_found}
      token ->
        Logger.info("Token found for portal: #{portal_id}")
        decrypted_token = SecureOAuthToken.decrypt_tokens(token)
        Logger.debug("Decrypted token: #{inspect(decrypted_token, pretty: true)}")
        if token_expired?(decrypted_token) or token_expiring_soon?(decrypted_token) do
          Logger.info("Token expired or expiring soon for portal: #{portal_id}, refreshing")
          case refresh_token(decrypted_token) do
            {:ok, refreshed_token} ->
              Logger.info("Token refreshed successfully for portal: #{portal_id}")
              {:ok, refreshed_token}
            {:error, _reason} = error ->
              Logger.error("Failed to refresh token for portal: #{portal_id}")
              error
          end
        else
          Logger.info("Token valid for portal: #{portal_id}")
          {:ok, decrypted_token}
        end
    end
  end

  def refresh_token(token) do
    Logger.info("Refreshing token for portal: #{token.portal_id}")
    Logger.debug("Token before refresh: #{inspect(token, pretty: true)}")
    case do_refresh_token(token) do
      {:ok, new_token_data} ->
        Logger.info("Token refreshed successfully for portal: #{token.portal_id}")
        Logger.debug("New token data: #{inspect(new_token_data, pretty: true)}")
        new_attrs = %{
          access_token: new_token_data["access_token"],
          refresh_token: new_token_data["refresh_token"],
          expires_at: calculate_expiration(new_token_data["expires_in"])
        }
        case update_token(token, new_attrs) do
          {:ok, updated_token} ->
            Logger.info("Token updated in database for portal: #{token.portal_id}")
            decrypted_token = SecureOAuthToken.decrypt_tokens(updated_token)
            Logger.debug("Decrypted token: #{inspect(decrypted_token, pretty: true)}")
            {:ok, decrypted_token}
          {:error, reason} ->
            Logger.error("Failed to update token in database for portal #{token.portal_id}: #{inspect(reason)}")
            {:error, :token_update_failed}
        end
      {:error, reason} ->
        Logger.error("Failed to refresh token for portal #{token.portal_id}: #{inspect(reason)}")
        {:error, :token_refresh_failed}
    end
  end

  def update_token(existing_token, attrs) do
    # Ensure we're only updating the fields that exist in the SecureOAuthToken schema
    update_attrs = Map.take(attrs, [:access_token, :refresh_token, :expires_at])

    # Check if the new tokens are already encrypted
    new_attrs = if is_encrypted?(update_attrs[:access_token]) do
      update_attrs
    else
      Map.merge(update_attrs, %{
        access_token: Throttle.Encryption.encrypt(update_attrs[:access_token]),
        refresh_token: Throttle.Encryption.encrypt(update_attrs[:refresh_token])
      })
    end

    existing_token
    |> SecureOAuthToken.update_changeset(new_attrs)
    |> Repo.update()
  end

  defp is_encrypted?(token) when is_binary(token) do
    case Base.decode64(token) do
      {:ok, _} -> true
      :error -> false
    end
  end
  defp is_encrypted?(_), do: false

  defp encrypt_token(token) do
    Logger.debug("Encrypting token for portal: #{token.portal_id}")
    encrypted = %{token |
      access_token: Encryption.encrypt(token.access_token),
      refresh_token: Encryption.encrypt(token.refresh_token)
    }
    Logger.debug("Token encrypted")
    encrypted
  end

  defp decrypt_token(token) do
    Logger.debug("Decrypting token for portal: #{token.portal_id}")
    decrypted = %{token |
      access_token: Encryption.decrypt(token.access_token),
      refresh_token: Encryption.decrypt(token.refresh_token)
    }
    Logger.debug("Token decrypted")
    decrypted
  end

  def token_expired?(token) do
    is_expired = DateTime.compare(token.expires_at, DateTime.utc_now()) == :lt
    Logger.info("Token expiration check for portal #{token.portal_id}: #{is_expired}")
    Logger.debug("Token expires at: #{token.expires_at}, Current time: #{DateTime.utc_now()}")
    Logger.debug("Token will expire in: #{DateTime.diff(token.expires_at, DateTime.utc_now(), :second)} seconds")
    is_expired
  end

  defp token_expiring_soon?(token) do
    expiring_soon = DateTime.diff(token.expires_at, DateTime.utc_now()) < 300 # 5 minutes
    Logger.info("Token expiring soon check for portal #{token.portal_id}: #{expiring_soon}")
    expiring_soon
  end

  defp do_refresh_token(token) do
    Logger.info("Performing token refresh for portal: #{token.portal_id}")
    body = URI.encode_query(%{
      grant_type: "refresh_token",
      client_id: hubspot_client_id(),
      client_secret: hubspot_client_secret(),
      refresh_token: token.refresh_token
    })

    headers = [{"Content-Type", "application/x-www-form-urlencoded"}]

    Logger.debug("Sending refresh token request to HubSpot")
    case HTTPoison.post(@hubspot_oauth_url, body, headers) do
      {:ok, %HTTPoison.Response{status_code: 200, body: resp_body}} ->
        Logger.info("Token refresh successful")
        decoded_body = Jason.decode!(resp_body)
        Logger.debug("Decoded response: #{inspect(decoded_body, pretty: true)}")
        {:ok, decoded_body}

      {:ok, %HTTPoison.Response{status_code: status_code, body: resp_body}} ->
        Logger.error("HubSpot API returned non-200 status code: #{status_code}, body: #{resp_body}")
        {:error, "HubSpot API returned status code: #{status_code}, body: #{resp_body}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("HubSpot API request failed: #{reason}")
        {:error, "HubSpot API request failed: #{reason}"}
    end
  end

  defp calculate_expiration(expires_in) do
    expiration = DateTime.add(DateTime.utc_now(), expires_in, :second)
    Logger.debug("Calculated token expiration: #{expiration}")
    expiration
  end

  defp hubspot_client_id do
    client_id = Application.get_env(:throttle, :hubspot_client_id) ||
      raise "HubSpot Client ID not set. Please set the HUBSPOT_CLIENT_ID environment variable."
    Logger.debug("Using HubSpot Client ID: #{client_id}")
    client_id
  end

  defp hubspot_client_secret do
    Application.get_env(:throttle, :hubspot_client_secret) ||
      raise "HubSpot Client Secret not set. Please set the HUBSPOT_CLIENT_SECRET environment variable."
  end
end
