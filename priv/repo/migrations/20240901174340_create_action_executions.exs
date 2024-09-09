defmodule Throttle.Repo.Migrations.AddFieldsToActionExecutions do
  use Ecto.Migration

  def change do
    alter table(:action_executions) do
      add :max_throughput, :string
      add :time, :string
      add :period, :string
    end
  end
end
