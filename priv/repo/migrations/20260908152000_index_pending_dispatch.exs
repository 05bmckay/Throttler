defmodule Throttle.Repo.Migrations.IndexPendingDispatch do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # Additive online migration for the durable dispatcher only. Run separately
    # from the release build; no scheduling state, rates, or deadlines change.
    execute("SET lock_timeout = '5s'")
    execute("SET statement_timeout = '5min'")

    create_if_not_exists(
      index(:action_executions, [:queue_id, :rate_reserved, :inserted_at, :id],
        name: :action_executions_pending_dispatch_index,
        where: "NOT processed AND NOT permanently_failed",
        concurrently: true
      )
    )

    execute("""
    DO $$ BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_index
        WHERE indexrelid = 'action_executions_pending_dispatch_index'::regclass
          AND indisvalid AND indisready
      ) THEN
        RAISE EXCEPTION 'Pending dispatch index is invalid; repair before retrying migration';
      END IF;
    END $$
    """)

    # The pending subset changes much faster than the millions of retained
    # terminal rows. Do not wait for the default 10% of history to change.
    execute("""
    ALTER TABLE action_executions SET (
      autovacuum_analyze_scale_factor = 0.001,
      autovacuum_analyze_threshold = 1000
    )
    """)

    execute("ANALYZE action_executions")
    execute("RESET lock_timeout")
    execute("RESET statement_timeout")
  end

  def down do
    raise "Forward-only incident fix; keep the additive index and planner statistics settings."
  end
end
