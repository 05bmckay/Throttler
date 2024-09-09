defmodule Throttle.Schemas.ActionExecution do
  use Ecto.Schema
  import Ecto.Changeset

  schema "action_executions" do
    field :queue_id, :string
    field :callback_id, :string
    field :processed, :boolean, default: false
    field :max_throughput, :string
    field :time, :string
    field :period, :string

    timestamps()
  end

  def changeset(action_execution, attrs) do
    action_execution
    |> cast(attrs, [:queue_id, :callback_id, :processed, :max_throughput, :time, :period])
    |> validate_required([:queue_id, :callback_id])
  end
end
