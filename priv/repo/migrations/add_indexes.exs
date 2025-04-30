defmodule Throttle.Repo.Migrations.AddIndexes do
  use Ecto.Migration

  def change do
    create index(:action_executions, [:queue_id])
    create index(:action_executions, [:processed])
    create index(:action_executions, [:inserted_at])
  end
end
