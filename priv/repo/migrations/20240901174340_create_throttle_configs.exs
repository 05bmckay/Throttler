defmodule Throttle.Repo.Migrations.CreateThrottleConfigs do
  use Ecto.Migration

  def change do
    create table(:throttle_configs) do
      add :portal_id, :integer
      add :action_id, :string
      add :max_throughput, :integer
      add :time_period, :integer
      add :time_unit, :string

      timestamps()
    end

    create unique_index(:throttle_configs, [:portal_id, :action_id])
  end
end
