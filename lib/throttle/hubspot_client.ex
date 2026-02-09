defmodule Throttle.HubSpotClient do
  @moduledoc """
  HTTP client for HubSpot API callbacks.

  Handles sending batch completion requests to HubSpot's automation API,
  including retry logic and rate-limit handling.
  """

  require Logger

  @doc """
  Sends a batch complete request to HubSpot with retry support.

  Retries on non-rate-limit errors up to `retries` times with a 2s delay.
  Returns `:ok` on success, or `{:error, reason}` on failure.
  """
  def send_batch_complete_with_retry(executions, access_token, retries \\ 3) do
    case send_batch_complete(executions, access_token) do
      :ok ->
        :ok

      {:error, {:rate_limited, retry_after}} when retries > 0 ->
        Logger.warning(fn ->
          "Rate limited by HubSpot API, will snooze for #{retry_after}s (#{retries} retries left)"
        end)

        {:error, {:rate_limited, retry_after}}

      {:error, reason} when retries > 0 ->
        Logger.warning(fn ->
          "Error occurred: #{inspect(reason)}, retrying (#{retries} retries left)"
        end)

        Process.sleep(2000)
        send_batch_complete_with_retry(executions, access_token, retries - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Sends a batch completion callback to HubSpot's automation API.

  Builds and sends an HTTP POST to the HubSpot callbacks endpoint with
  the given executions marked as SUCCESS. Handles 204, 403, 429, and
  other status codes appropriately.
  """
  def send_batch_complete(executions, access_token) do
    Logger.info(fn -> "Sending batch complete for #{length(executions)} executions" end)
    url = "https://api.hubapi.com/automation/v4/actions/callbacks/complete"

    body =
      Jason.encode!(%{
        inputs:
          Enum.map(executions, fn execution ->
            %{
              callbackId: execution.callback_id,
              outputFields: %{hs_execution_state: "SUCCESS"}
            }
          end)
      })

    headers = [
      {"Authorization", "Bearer #{access_token}"},
      {"Content-Type", "application/json"}
    ]

    request = Finch.build(:post, url, headers, body)

    case Finch.request(request, Throttle.Finch, receive_timeout: 15_000, request_timeout: 30_000) do
      {:ok, %Finch.Response{status: 204}} ->
        Logger.debug("Batch complete request successful")
        :ok

      {:ok, %Finch.Response{status: 403, body: response_body}} ->
        # Handle Cloudflare/other 403 block specifically
        ray_id = extract_cloudflare_ray_id(response_body)
        Logger.error("API request blocked (403 Forbidden). Ray ID: #{ray_id || "Not Found"}.")
        # Return error without crashing
        {:error, {:http_error, 403, response_body}}

      {:ok, %Finch.Response{status: 429, headers: response_headers}} ->
        retry_after = extract_retry_after(response_headers) || 60
        Logger.warning("Rate limited by HubSpot API (429), retry after #{retry_after} seconds")

        # Emit telemetry event for rate limiting
        :telemetry.execute(
          [:throttle, :api, :rate_limited],
          %{retry_after: retry_after},
          %{}
        )

        {:error, {:rate_limited, retry_after}}

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        # Attempt to parse other errors as JSON, but handle potential decode errors
        case Jason.decode(response_body) do
          {:ok, parsed_body} ->
            Logger.error("API error: Status #{status}, Body: #{inspect(parsed_body)}")

            {:error, {:api_error, status, parsed_body}}

          {:error, decode_error} ->
            Logger.error(
              "API error: Status #{status}, Failed to decode JSON body: #{inspect(decode_error)}, Body: #{inspect(response_body)}"
            )

            {:error, {:http_error, status, response_body}}
        end

      {:error, exception} ->
        Logger.error("HTTP error: #{Exception.message(exception)}")
        {:error, {:http_error, Exception.message(exception)}}
    end
  end

  # Extract Retry-After header value from response headers
  defp extract_retry_after(headers) do
    headers
    |> Enum.find_value(fn
      {"Retry-After", value} -> String.to_integer(value)
      _ -> nil
    end)
  end

  # Extract Cloudflare Ray ID from HTML error response body
  defp extract_cloudflare_ray_id(body) when is_binary(body) do
    case Regex.run(~r/Cloudflare Ray ID: <strong[^>]*>([a-f0-9]+)<\/strong>/i, body) do
      [_, ray_id] -> ray_id
      _ -> nil
    end
  end

  defp extract_cloudflare_ray_id(_), do: nil
end
