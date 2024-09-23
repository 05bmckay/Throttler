defmodule Throttle.Repo.Migrations.CreateActionExecutions do
  use Ecto.Migration

  def change do
    create table(:action_executions) do
      add :queue_id, :string
      add :callback_id, :string
      add :processed, :boolean, default: false
      add :max_throughput, :string
      add :time, :string
      add :period, :string

      timestamps()
    end
  end
end
