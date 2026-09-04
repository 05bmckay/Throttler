defmodule ThrottleTest do
  use ExUnit.Case, async: true

  alias Throttle.DispatchSupervisor
  alias Throttle.Schemas.{ActionExecution, ThrottleConfig}

  test "scheduler and tasks restart together without orphaned delivery" do
    assert {:ok, {%{strategy: :one_for_all}, children}} = DispatchSupervisor.init([])
    assert length(children) == 2
    assert {:ok, _rate} = Throttle.Rate.parse(runner_config().max_throughput, "1", "seconds")
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
