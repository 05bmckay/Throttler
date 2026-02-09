defmodule Throttle.Repo.Migrations.AddTotalAttemptsToActionExecutions do
  use Ecto.Migration

  def change do
    alter table(:action_executions) do
      add(:total_attempts, :integer, default: 0, null: false)
      add(:permanently_failed, :boolean, default: false, null: false)
    end

    create(
      index(:action_executions, [:permanently_failed],
        where: "permanently_failed = false AND processed = false",
        name: :action_executions_active_idx
      )
    )
  end
end
