defmodule Throttle.Repo.Migrations.IsolateInvalidCallbackBatches do
  use Ecto.Migration

  def change do
    alter table(:dispatch_portals) do
      add(:isolated_until, :utc_datetime_usec)
    end
  end
end
