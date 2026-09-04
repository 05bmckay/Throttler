defmodule Throttle.QueueManager do
  @moduledoc "Validates the complete queue identity before admission."
  def create_queue_identifier(params) do
    with {:ok, portal} <- Throttle.Rate.positive(get_in(params, ["origin", "portalId"])),
         {:ok, workflow} <- segment(get_in(params, ["context", "workflowId"])),
         {:ok, action} <- segment(get_in(params, ["origin", "actionDefinitionId"])),
         {:ok, index} <-
           segment(
             get_in(params, ["origin", "actionExecutionIndexIdentifier", "actionExecutionIndex"]) ||
               0
           ) do
      {:ok, "queue:#{portal}:#{workflow}:#{action}:#{index}"}
    else
      _ -> {:error, "Invalid queue identity"}
    end
  end

  defp segment(value) when is_integer(value) and value >= 0, do: {:ok, Integer.to_string(value)}

  defp segment(value) when is_binary(value) do
    if byte_size(value) in 1..64 and not String.contains?(value, ":"),
      do: {:ok, value},
      else: {:error, :invalid_segment}
  end

  defp segment(_), do: {:error, :invalid_segment}
end
