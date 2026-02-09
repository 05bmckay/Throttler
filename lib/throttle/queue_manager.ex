defmodule Throttle.QueueManager do
  require Logger

  def create_queue_identifier(params) do
    portal_id = get_in(params, ["origin", "portalId"])
    workflow_id = get_in(params, ["context", "workflowId"])
    action_id = get_in(params, ["origin", "actionDefinitionId"])

    execution_index =
      get_in(params, ["origin", "actionExecutionIndexIdentifier", "actionExecutionIndex"])

    components = [portal_id, workflow_id, action_id, execution_index]

    if Enum.any?(components, &is_nil/1) do
      Logger.warning(
        "Queue identifier has nil components: #{inspect(components)} from params: #{inspect(params)}"
      )
    end

    "queue:#{portal_id || "unknown"}:#{workflow_id || "unknown"}:#{action_id || "unknown"}:#{execution_index || "0"}"
  end
end
