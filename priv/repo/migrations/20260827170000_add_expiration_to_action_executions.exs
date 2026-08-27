defmodule Throttle.Repo.Migrations.AddExpirationToActionExecutions do
  use Ecto.Migration

  def up do
    alter table(:action_executions) do
      add_if_not_exists(:expires_at, :utc_datetime)
    end

    create_if_not_exists(
      index(:action_executions, [:expires_at],
        where: "processed = false AND permanently_failed = false AND expires_at IS NOT NULL",
        name: :action_executions_pending_expiration_index
      )
    )
  end

  def down do
    drop_if_exists(
      index(:action_executions, [:expires_at], name: :action_executions_pending_expiration_index)
    )

    alter table(:action_executions) do
      remove(:expires_at)
    end
  end
end
