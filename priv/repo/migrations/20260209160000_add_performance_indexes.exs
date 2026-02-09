defmodule Throttle.Repo.Migrations.AddPerformanceIndexes do
  use Ecto.Migration

  def change do
    # P1-4: Composite partial index on (queue_id, processed) — the hot query path.
    # Every batch processing cycle queries WHERE queue_id = ? AND processed = false.
    create(
      index(:action_executions, [:queue_id, :processed],
        where: "processed = false",
        name: :action_executions_queue_id_unprocessed_index
      )
    )

    # P2-8: Unique index on oauth_tokens.portal_id — prevents duplicate tokens per portal.
    create_if_not_exists(unique_index(:oauth_tokens, [:portal_id]))
  end
end
