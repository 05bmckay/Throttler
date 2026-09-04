defmodule Throttle.HubSpotClient do
  @moduledoc """
  HTTP client for HubSpot API callbacks.

  Handles sending batch completion requests to HubSpot's automation API,
  returning one result for the durable dispatcher to schedule.
  """

  require Logger

  @doc """
  Sends a batch completion callback to HubSpot's automation API.

  Builds and sends an HTTP POST to the HubSpot callbacks endpoint with
  the given executions marked as SUCCESS. Handles 204, 403, 429, and
  other status codes appropriately.
  """
  def send_batch_complete(executions, access_token) do
    Logger.debug(fn -> "Sending batch complete for #{length(executions)} executions" end)
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

    case Throttle.HTTP.request(request) do
      {:ok, %Finch.Response{status: 204}} ->
        Logger.debug("Batch complete request successful")
        :ok

      {:ok, %Finch.Response{status: 401, body: _response_body}} ->
        Logger.warning("HubSpot API returned 401 Unauthorized")
        {:error, :unauthorized}

      {:ok, %Finch.Response{status: 403, body: response_body}} ->
        # Handle Cloudflare/other 403 block specifically
        ray_id = extract_cloudflare_ray_id(response_body)
        Logger.error("API request blocked (403 Forbidden). Ray ID: #{ray_id || "Not Found"}.")
        # Return error without crashing
        {:error, {:http_error, 403}}

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

      {:ok, %Finch.Response{status: status}} ->
        Logger.error("HubSpot callback API returned status #{status}")
        {:error, {:api_error, status}}

      {:error, exception} ->
        Logger.error("HTTP error: #{Exception.message(exception)}")
        {:error, {:http_error, Exception.message(exception)}}
    end
  end

  # Longest Retry-After honoured. The durable portal holds every send for this long,
  # so an unbounded (or negative) header must never reach the timer.
  @max_retry_after_seconds 3_600

  # Extract Retry-After header value from response headers, clamped to
  # [0, @max_retry_after_seconds]. Unparseable or negative values yield nil so
  # the caller falls back to its default.
  defp extract_retry_after(headers) do
    headers
    |> Enum.find_value(fn {name, value} ->
      if String.downcase(name) == "retry-after" do
        case Integer.parse(String.trim(value)) do
          {int, ""} when int >= 0 -> min(int, @max_retry_after_seconds)
          _ -> nil
        end
      else
        nil
      end
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
