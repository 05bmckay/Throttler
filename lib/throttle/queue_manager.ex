defmodule Throttle.QueueManager do
  def create_queue_identifier(params) do
    portal_id = get_in(params, ["origin", "portalId"])
    workflow_id = get_in(params, ["context", "workflowId"])
    action_id = get_in(params, ["origin", "actionDefinitionId"])
    execution_index = get_in(params, ["origin", "actionExecutionIndexIdentifier", "actionExecutionIndex"])

    "queue:#{portal_id}:#{workflow_id}:#{action_id}:#{execution_index}"
  end
end
