defmodule ThrottleTest do
  use ExUnit.Case, async: true

  alias Throttle.QueueRunner
  alias Throttle.Schemas.{ActionExecution, ThrottleConfig}

  test "QueueRunner normal exits are not restarted" do
    child_spec = QueueRunner.child_spec({"queue:1:2:3:0", runner_config()})

    assert child_spec.restart == :transient
  end

  test "action executions require every value needed by the runner" do
    changeset = ActionExecution.changeset(%ActionExecution{}, %{})

    refute changeset.valid?

    assert Enum.sort(Keyword.keys(changeset.errors)) ==
             Enum.sort([:queue_id, :callback_id, :max_throughput, :time, :period])
  end

  test "throttle configs accept HubSpot's plural time units" do
    attrs = %{
      portal_id: 42,
      action_id: "action",
      max_throughput: 3,
      time_period: 1,
      time_unit: "seconds"
    }

    assert %Ecto.Changeset{valid?: true} =
             ThrottleConfig.changeset(%ThrottleConfig{}, attrs)
  end

  defp runner_config do
    %{max_throughput: "3", time: "1", period: "seconds"}
  end
end
