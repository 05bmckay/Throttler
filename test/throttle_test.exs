defmodule ThrottleTest do
  use Throttle.DataCase

  alias Throttle
  alias Throttle.Schemas.{ThrottleConfig, ActionExecution}

  describe "throttle_config" do
    @valid_attrs %{
      portal_id: 42,
      action_id: "some-action",
      max_throughput: 100,
      time_period: 60,
      time_unit: "second"
    }
    @update_attrs %{max_throughput: 200, time_period: 120, time_unit: "minute"}
    @invalid_attrs %{
      portal_id: nil,
      action_id: nil,
      max_throughput: nil,
      time_period: nil,
      time_unit: nil
    }

    test "get_throttle_config/2 returns the throttle config with given portal_id and action_id" do
      {:ok, config} = Throttle.upsert_throttle_config(@valid_attrs)
      assert Throttle.get_throttle_config(config.portal_id, config.action_id) == config
    end

    test "upsert_throttle_config/1 with valid data creates a throttle config" do
      assert {:ok, %ThrottleConfig{} = config} = Throttle.upsert_throttle_config(@valid_attrs)
      assert config.portal_id == 42
      assert config.action_id == "some-action"
      assert config.max_throughput == 100
      assert config.time_period == 60
      assert config.time_unit == "second"
    end

    test "upsert_throttle_config/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Throttle.upsert_throttle_config(@invalid_attrs)
    end

    test "upsert_throttle_config/1 with existing config updates the config" do
      {:ok, config} = Throttle.upsert_throttle_config(@valid_attrs)

      assert {:ok, %ThrottleConfig{} = updated_config} =
               Throttle.upsert_throttle_config(Map.merge(@valid_attrs, @update_attrs))

      assert updated_config.id == config.id
      assert updated_config.max_throughput == 200
      assert updated_config.time_period == 120
      assert updated_config.time_unit == "minute"
    end
  end

  describe "action_execution" do
    @valid_attrs %{queue_id: "some-queue", callback_id: "some-callback"}

    test "create_action_execution/1 with valid data creates an action execution" do
      assert {:ok, %ActionExecution{} = execution} =
               Throttle.create_action_execution(@valid_attrs)

      assert execution.queue_id == "some-queue"
      assert execution.callback_id == "some-callback"
      assert execution.processed == false
    end

    test "get_next_action_batch/2 returns the next batch of unprocessed actions" do
      {:ok, _} = Throttle.create_action_execution(@valid_attrs)
      {:ok, _} = Throttle.create_action_execution(@valid_attrs)

      assert [%ActionExecution{}, %ActionExecution{}] =
               Throttle.get_next_action_batch("some-queue", 2)
    end

    test "mark_actions_processed/1 marks actions as processed" do
      {:ok, execution1} = Throttle.create_action_execution(@valid_attrs)
      {:ok, execution2} = Throttle.create_action_execution(@valid_attrs)
      Throttle.mark_actions_processed([execution1.id, execution2.id])
      assert Repo.get(ActionExecution, execution1.id).processed
      assert Repo.get(ActionExecution, execution2.id).processed
    end
  end
end
