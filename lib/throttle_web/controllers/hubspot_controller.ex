defmodule ThrottleWeb.HubSpotController do
  use ThrottleWeb, :controller
  require Logger

  def handle_action(conn, params) do
    with {:ok, _portal_id} <- validate_portal_id(get_in(params, ["origin", "portalId"])),
         {:ok, _action_id} <- validate_action_id(get_in(params, ["origin", "actionDefinitionId"])),
         queue_id <- Throttle.create_queue_identifier(params),
         result <- Throttle.create_action_execution(%{
           queue_id: queue_id,
           callback_id: params["callbackId"],
           processed: false,
           max_throughput: get_in(params, ["inputFields", "maxThroughPut"]),
           time: get_in(params, ["inputFields", "time"]),
           period: get_in(params, ["inputFields", "period"])
         }),
         :ok <- handle_create_action_result(result) do
      send_success_response(conn)
    else
      {:error, reason} ->
        send_error_response(conn, reason)
    end
  end

  defp validate_portal_id(nil), do: {:error, "Missing portal ID"}
  defp validate_portal_id(portal_id), do: {:ok, portal_id}

  defp validate_action_id(nil), do: {:error, "Missing action ID"}
  defp validate_action_id(action_id), do: {:ok, action_id}

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
    |> json(%{
      outputFields: %{
        hs_execution_state: "BLOCK"
      }
    })
  end

  defp send_error_response(conn, reason) do
    Logger.error("Error handling HubSpot action: #{inspect(reason)}")
    conn
    |> put_status(:bad_request)
    |> json(%{error: reason})
  end
end
