defmodule Throttle.OAuthManager do
  alias Throttle.{Repo, Schemas.SecureOAuthToken}
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

        # Merge token details with original token data for complete response
        full_token_response = Map.merge(token_data, token_details)

        %SecureOAuthToken{}
        |> SecureOAuthToken.changeset(%{
          portal_id: token_details["hub_id"],
          access_token: token_data["access_token"],
          refresh_token: token_data["refresh_token"],
          expires_at: calculate_expiration(token_data["expires_in"]),
          token_response: full_token_response,
          email: token_details["user"]
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

    request = Finch.build(:get, url, headers)

    case Finch.request(request, Throttle.Finch, receive_timeout: 15_000, request_timeout: 30_000) do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        Logger.info("Successfully fetched token details")
        {:ok, Jason.decode!(resp_body)}

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        Logger.error("Failed to fetch token details. Status code: #{status}, body: #{resp_body}")

        {:error, "Failed to fetch token details. Status code: #{status}, body: #{resp_body}"}

      {:error, exception} ->
        Logger.error(
          "HTTP request failed when fetching token details: #{Exception.message(exception)}"
        )

        {:error, "Failed to fetch token details: #{Exception.message(exception)}"}
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

        if token_expired?(decrypted_token) or token_expiring_soon?(decrypted_token) do
          Logger.info("Token expired or expiring soon for portal: #{portal_id}, refreshing")

          Throttle.OAuthRefreshLock.refresh_if_needed(portal_id, fn ->
            refresh_token(decrypted_token)
          end)
        else
          Logger.info("Token valid for portal: #{portal_id}")
          {:ok, decrypted_token}
        end
    end
  end

  def refresh_token(token) do
    Logger.info("Refreshing token for portal: #{token.portal_id}")

    case do_refresh_token(token) do
      {:ok, new_token_data} ->
        Logger.info("Token refreshed successfully for portal: #{token.portal_id}")

        # Only fetch token details if token_response is nil/empty
        new_attrs =
          if is_nil(token.token_response) or token.token_response == %{} do
            Logger.info("Token response is empty, fetching full token details")

            case fetch_token_details(new_token_data["access_token"]) do
              {:ok, token_details} ->
                full_token_response = Map.merge(new_token_data, token_details)

                %{
                  access_token: new_token_data["access_token"],
                  refresh_token: new_token_data["refresh_token"],
                  expires_at: calculate_expiration(new_token_data["expires_in"]),
                  token_response: full_token_response,
                  email: token_details["user"]
                }

              {:error, _} ->
                # If we can't fetch details, just update tokens without token_response
                %{
                  access_token: new_token_data["access_token"],
                  refresh_token: new_token_data["refresh_token"],
                  expires_at: calculate_expiration(new_token_data["expires_in"])
                }
            end
          else
            # Token response already exists, don't update it
            %{
              access_token: new_token_data["access_token"],
              refresh_token: new_token_data["refresh_token"],
              expires_at: calculate_expiration(new_token_data["expires_in"])
            }
          end

        case update_token(token, new_attrs) do
          {:ok, updated_token} ->
            Logger.info("Token updated in database for portal: #{token.portal_id}")
            decrypted_token = SecureOAuthToken.decrypt_tokens(updated_token)
            {:ok, decrypted_token}

          {:error, reason} ->
            Logger.error(
              "Failed to update token in database for portal #{token.portal_id}: #{inspect(reason)}"
            )

            {:error, :token_update_failed}
        end

      {:error, reason} ->
        Logger.error("Failed to refresh token for portal #{token.portal_id}: #{inspect(reason)}")
        {:error, :token_refresh_failed}
    end
  end

  def update_token(existing_token, attrs) do
    update_attrs =
      Map.take(attrs, [:access_token, :refresh_token, :expires_at, :token_response, :email])

    encrypted_attrs =
      Map.merge(update_attrs, %{
        access_token: Throttle.Encryption.encrypt(update_attrs[:access_token]),
        refresh_token: Throttle.Encryption.encrypt(update_attrs[:refresh_token])
      })

    existing_token
    |> SecureOAuthToken.update_changeset(encrypted_attrs)
    |> Repo.update()
  end

  def token_expired?(token) do
    is_expired = DateTime.compare(token.expires_at, DateTime.utc_now()) == :lt

    Logger.debug(
      "Token will expire in: #{DateTime.diff(token.expires_at, DateTime.utc_now(), :second)} seconds"
    )

    is_expired
  end

  defp token_expiring_soon?(token) do
    # 5 minutes
    expiring_soon = DateTime.diff(token.expires_at, DateTime.utc_now()) < 300
    Logger.info("Token expiring soon check for portal #{token.portal_id}: #{expiring_soon}")
    expiring_soon
  end

  defp do_refresh_token(token) do
    Logger.info("Performing token refresh for portal: #{token.portal_id}")

    body =
      URI.encode_query(%{
        grant_type: "refresh_token",
        client_id: hubspot_client_id(),
        client_secret: hubspot_client_secret(),
        refresh_token: token.refresh_token
      })

    headers = [{"Content-Type", "application/x-www-form-urlencoded"}]

    Logger.debug("Sending refresh token request to HubSpot")

    request = Finch.build(:post, @hubspot_oauth_url, headers, body)

    case Finch.request(request, Throttle.Finch, receive_timeout: 15_000, request_timeout: 30_000) do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        Logger.info("Token refresh successful")
        decoded_body = Jason.decode!(resp_body)
        {:ok, decoded_body}

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        Logger.error("HubSpot API returned non-200 status code: #{status}, body: #{resp_body}")

        {:error, "HubSpot API returned status code: #{status}, body: #{resp_body}"}

      {:error, exception} ->
        Logger.error("HubSpot API request failed: #{Exception.message(exception)}")
        {:error, "HubSpot API request failed: #{Exception.message(exception)}"}
    end
  end

  defp calculate_expiration(expires_in) do
    expiration = DateTime.add(DateTime.utc_now(), expires_in, :second)
    Logger.debug("Calculated token expiration: #{expiration}")
    expiration
  end

  defp hubspot_client_id do
    client_id =
      Application.get_env(:throttle, :hubspot_client_id) ||
        raise "HubSpot Client ID not set. Please set the HUBSPOT_CLIENT_ID environment variable."

    Logger.debug("Using HubSpot Client ID: #{client_id}")
    client_id
  end

  defp hubspot_client_secret do
    Application.get_env(:throttle, :hubspot_client_secret) ||
      raise "HubSpot Client Secret not set. Please set the HUBSPOT_CLIENT_SECRET environment variable."
  end
end
