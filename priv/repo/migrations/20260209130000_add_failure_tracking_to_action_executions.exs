defmodule Throttle.Repo.Migrations.AddFailureTrackingToActionExecutions do
  use Ecto.Migration

  def change do
    alter table(:action_executions) do
      add_if_not_exists(:last_failure_reason, :string)
      add_if_not_exists(:consecutive_failures, :integer, default: 0, null: false)
      add_if_not_exists(:on_hold_until, :utc_datetime)
    end
  end
end
