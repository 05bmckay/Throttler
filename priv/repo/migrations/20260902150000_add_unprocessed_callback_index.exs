defmodule Throttle.Repo.Migrations.AddUnprocessedCallbackIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index_name :action_executions_unprocessed_callback_id_index

  def up do
    # An interrupted CREATE INDEX CONCURRENTLY leaves an INVALID index behind.
    # IF NOT EXISTS would then skip it on the next run and record this
    # migration as applied while the planner ignores the index.
    drop_invalid_index()

    create_if_not_exists(
      index(:action_executions, [:callback_id],
        where: "processed = false",
        name: @index_name,
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:action_executions, [:callback_id],
        name: @index_name,
        concurrently: true
      )
    )
  end

  defp drop_invalid_index do
    %{rows: rows} =
      repo().query!(
        """
        SELECT 1
        FROM pg_class c
        JOIN pg_index i ON i.indexrelid = c.oid
        WHERE c.relname = $1 AND NOT i.indisvalid
        """,
        [Atom.to_string(@index_name)]
      )

    if rows != [] do
      execute("DROP INDEX CONCURRENTLY IF EXISTS #{@index_name}")
    end
  end
end
