defmodule Throttle.Repo.Migrations.AddUnprocessedCallbackIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(
      index(:action_executions, [:callback_id],
        where: "processed = false",
        name: :action_executions_unprocessed_callback_id_index,
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:action_executions, [:callback_id],
        name: :action_executions_unprocessed_callback_id_index,
        concurrently: true
      )
    )
  end
end
