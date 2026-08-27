defmodule ThrottleWeb.HubSpotController do
  use ThrottleWeb, :controller
  require Logger

  def handle_action(conn, params) do
    with {:ok, _portal_id} <- validate_portal_id(get_in(params, ["origin", "portalId"])),
         {:ok, _action_id} <- validate_action_id(get_in(params, ["origin", "actionDefinitionId"])),
         {:ok, callback_id} <- required(params["callbackId"], "callback ID"),
         {:ok, max_throughput} <-
           positive_integer(get_in(params, ["inputFields", "maxThroughPut"]), "max throughput"),
         {:ok, time} <- positive_integer(get_in(params, ["inputFields", "time"]), "time"),
         {:ok, period} <- normalize_period(get_in(params, ["inputFields", "period"])),
         queue_id <- Throttle.create_queue_identifier(params),
         result <-
           Throttle.create_action_execution(%{
             queue_id: queue_id,
             callback_id: callback_id,
             processed: false,
             max_throughput: max_throughput,
             time: time,
             period: period
           }),
         :ok <- handle_create_action_result(result) do
      send_success_response(conn)
    else
      {:error, reason} when reason in [:overloaded, :unavailable] ->
        send_retryable_error_response(conn, reason)

      {:error, reason} ->
        send_error_response(conn, reason)
    end
  end

  defp validate_portal_id(nil), do: {:error, "Missing portal ID"}
  defp validate_portal_id(portal_id), do: {:ok, portal_id}

  defp validate_action_id(nil), do: {:error, "Missing action ID"}
  defp validate_action_id(action_id), do: {:ok, action_id}

  defp required(nil, field), do: {:error, "Missing #{field}"}
  defp required("", field), do: {:error, "Missing #{field}"}
  defp required(value, _field), do: {:ok, value}

  defp positive_integer(value, field) do
    case Integer.parse(to_string(value || "")) do
      {integer, ""} when integer > 0 -> {:ok, Integer.to_string(integer)}
      _ -> {:error, "Invalid #{field}: must be a positive integer"}
    end
  end

  defp normalize_period(period) when period in ["second", "seconds"], do: {:ok, "seconds"}
  defp normalize_period(period) when period in ["minute", "minutes"], do: {:ok, "minutes"}
  defp normalize_period(period) when period in ["hour", "hours"], do: {:ok, "hours"}
  defp normalize_period(period) when period in ["day", "days"], do: {:ok, "days"}
  defp normalize_period(_period), do: {:error, "Invalid period"}

  defp handle_create_action_result(:ok), do: :ok
  defp handle_create_action_result({:ok, _}), do: :ok
  defp handle_create_action_result({:error, reason}), do: {:error, reason}

  defp handle_create_action_result(unexpected) do
    Logger.error("Unexpected result from create_action_execution: #{inspect(unexpected)}")
    {:error, "Internal server error"}
  end

  defp send_success_response(conn) do
    conn
    |> put_status(:ok)
    |> json(%{outputFields: block_output_fields()})
  end

  def block_output_fields do
    %{
      hs_execution_state: "BLOCK",
      hs_expiration_duration:
        Application.fetch_env!(:throttle, :hubspot_block_expiration_duration)
    }
  end

  defp send_error_response(conn, reason) do
    Logger.error("Error handling HubSpot action: #{inspect(reason)}")

    conn
    |> put_status(:bad_request)
    |> json(%{error: reason})
  end

  defp send_retryable_error_response(conn, reason) do
    Logger.error("Throttler temporarily unavailable: #{inspect(reason)}")

    conn
    |> put_status(:service_unavailable)
    |> put_resp_header("retry-after", "30")
    |> json(%{error: "Throttler temporarily unavailable"})
  end
end
