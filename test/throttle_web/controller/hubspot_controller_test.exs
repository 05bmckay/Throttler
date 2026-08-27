defmodule ThrottleWeb.HubSpotControllerTest do
  use ExUnit.Case, async: true
  import Phoenix.ConnTest

  alias ThrottleWeb.HubSpotController

  test "BLOCK response includes an explicit expiration window" do
    assert %{
             hs_execution_state: "BLOCK",
             hs_expiration_duration: "P4W"
           } = HubSpotController.block_output_fields()
  end

  test "rejects invalid rate settings instead of creating an undrainable action" do
    conn =
      build_conn()
      |> HubSpotController.handle_action(%{
        "callbackId" => "callback-invalid",
        "origin" => %{"portalId" => 42, "actionDefinitionId" => "action-1"},
        "context" => %{"workflowId" => 123},
        "inputFields" => %{
          "maxThroughPut" => "0",
          "time" => "1",
          "period" => "fortnights"
        }
      })

    assert %{"error" => "Invalid max throughput: must be a positive integer"} =
             json_response(conn, 400)
  end
end
