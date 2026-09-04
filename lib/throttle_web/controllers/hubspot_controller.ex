defmodule ThrottleWeb.HubSpotController do
  use ThrottleWeb, :controller
  require Logger

  def handle_action(
        conn,
        %{"origin" => origin, "context" => context, "inputFields" => inputs} = params
      )
      when is_map(origin) and is_map(context) and is_map(inputs) do
    with {:ok, _portal_id} <- validate_portal_id(get_in(params, ["origin", "portalId"])),
         {:ok, _action_id} <- validate_action_id(get_in(params, ["origin", "actionDefinitionId"])),
         {:ok, callback_id} <- required(params["callbackId"], "callback ID"),
         {:ok, max_throughput} <-
           positive_integer(get_in(params, ["inputFields", "maxThroughPut"]), "max throughput"),
         {:ok, time} <- positive_integer(get_in(params, ["inputFields", "time"]), "time"),
         {:ok, period} <- normalize_period(get_in(params, ["inputFields", "period"])),
         {:ok, queue_id} <- Throttle.create_queue_identifier(params),
         result <-
           Throttle.create_action_execution(%{
             queue_id: queue_id,
             callback_id: callback_id,
             processed: false,
             max_throughput: max_throughput,
             time: time,
             period: period,
             expires_at: Throttle.BlockExpiration.expires_at()
           }),
         {:ok, action} <- result do
      send_success_response(conn, action)
    else
      {:error, reason} when reason in [:overloaded, :unavailable] ->
        send_retryable_error_response(conn, reason)

      {:error, reason} ->
        send_error_response(conn, reason)
    end
  end

  def handle_action(conn, _params), do: send_error_response(conn, "Invalid action payload")

  defp validate_portal_id(nil), do: {:error, "Missing portal ID"}
  defp validate_portal_id(portal_id), do: {:ok, portal_id}

  defp validate_action_id(nil), do: {:error, "Missing action ID"}
  defp validate_action_id(action_id), do: {:ok, action_id}

  defp required(nil, field), do: {:error, "Missing #{field}"}
  defp required("", field), do: {:error, "Missing #{field}"}
  defp required(value, _field), do: {:ok, value}

  defp positive_integer(value, field) do
    case Throttle.Rate.positive(value) do
      {:ok, integer} -> {:ok, Integer.to_string(integer)}
      _ -> {:error, "Invalid #{field}: must be a positive integer"}
    end
  end

  defp normalize_period(period) when period in ["second", "seconds"], do: {:ok, "seconds"}
  defp normalize_period(period) when period in ["minute", "minutes"], do: {:ok, "minutes"}
  defp normalize_period(period) when period in ["hour", "hours"], do: {:ok, "hours"}
  defp normalize_period(period) when period in ["day", "days"], do: {:ok, "days"}
  defp normalize_period(_period), do: {:error, "Invalid period"}

  defp send_success_response(conn, action) do
    fields =
      cond do
        action.processed ->
          %{hs_execution_state: "SUCCESS"}

        action.permanently_failed ->
          %{hs_execution_state: "FAIL_CONTINUE"}

        is_nil(action.expires_at) or
            DateTime.compare(action.expires_at, DateTime.utc_now()) != :gt ->
          %{hs_execution_state: "FAIL_CONTINUE"}

        true ->
          seconds = max(DateTime.diff(action.expires_at, DateTime.utc_now(), :second), 1)
          %{hs_execution_state: "BLOCK", hs_expiration_duration: "PT#{seconds}S"}
      end

    json(conn, %{outputFields: fields})
  end

  def block_output_fields do
    %{
      hs_execution_state: "BLOCK",
      hs_expiration_duration: Throttle.BlockExpiration.configured_duration()
    }
  end

  defp send_error_response(conn, reason) do
    Logger.error("Error handling HubSpot action: #{inspect(reason)}")

    conn
    |> put_status(:bad_request)
    |> json(%{error: to_string(reason)})
  end

  defp send_retryable_error_response(conn, reason) do
    Logger.error("Throttler temporarily unavailable: #{inspect(reason)}")

    conn
    |> put_status(:service_unavailable)
    |> put_resp_header("retry-after", "30")
    |> json(%{error: "Throttler temporarily unavailable"})
  end
end
