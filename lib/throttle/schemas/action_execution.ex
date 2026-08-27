defmodule Throttle.Schemas.ActionExecution do
  use Ecto.Schema
  import Ecto.Changeset

  schema "action_executions" do
    field(:queue_id, :string)
    field(:callback_id, :string)
    field(:processed, :boolean, default: false)
    field(:max_throughput, :string)
    field(:time, :string)
    field(:period, :string)
    field(:expires_at, :utc_datetime)

    field(:last_failure_reason, :string)
    field(:consecutive_failures, :integer, default: 0)
    field(:on_hold_until, :utc_datetime)
    field(:total_attempts, :integer, default: 0)
    field(:permanently_failed, :boolean, default: false)

    timestamps()
  end

  def changeset(action_execution, attrs) do
    action_execution
    |> cast(attrs, [
      :queue_id,
      :callback_id,
      :processed,
      :max_throughput,
      :time,
      :period,
      :expires_at,
      :last_failure_reason,
      :consecutive_failures,
      :on_hold_until,
      :total_attempts,
      :permanently_failed
    ])
    |> validate_required([:queue_id, :callback_id, :max_throughput, :time, :period])
  end
end
