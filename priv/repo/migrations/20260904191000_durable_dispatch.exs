defmodule Throttle.Repo.Migrations.DurableDispatch do
  use Ecto.Migration

  def up do
    # Offline cutover only: see docs/readiness/ROLLOUT.md. Older binaries must
    # stop before this transaction; they do not honor the new ownership model.
    execute("SET LOCAL lock_timeout = '5s'")
    execute("LOCK TABLE action_executions IN SHARE ROW EXCLUSIVE MODE")

    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM action_executions WHERE callback_id IS NULL OR callback_id = '') THEN
        RAISE EXCEPTION 'Invalid callback identity: repair before cutover';
      END IF;
      IF EXISTS (SELECT callback_id FROM action_executions GROUP BY callback_id
        HAVING count(DISTINCT queue_id) > 1) THEN
        RAISE EXCEPTION 'Callback identity spans multiple queues: reconcile before cutover';
      END IF;
      IF EXISTS (SELECT 1 FROM action_executions WHERE NOT processed AND NOT permanently_failed
        AND (queue_id !~ '^queue:[0-9]+:[^:]+:[^:]+:[^:]+$'
          OR max_throughput !~ '^[0-9]+$' OR time !~ '^[0-9]+$'
          OR period NOT IN ('second','seconds','minute','minutes','hour','hours','day','days'))) THEN
        RAISE EXCEPTION 'Invalid active queue configuration: repair before cutover';
      END IF;
    END $$;
    """)

    # One execution identity. A completed duplicate wins over pending copies;
    # otherwise retain a runnable copy before a permanently failed one.
    execute("""
    WITH ranked AS (
      SELECT id, row_number() OVER (
        PARTITION BY callback_id ORDER BY processed DESC, permanently_failed ASC, id ASC
      ) AS position FROM action_executions
    ) DELETE FROM action_executions a USING ranked r WHERE a.id = r.id AND r.position > 1
    """)

    execute(
      "UPDATE action_executions SET expires_at = inserted_at + interval '7 days' WHERE expires_at IS NULL AND NOT processed AND NOT permanently_failed"
    )

    create(unique_index(:action_executions, [:callback_id]))

    alter table(:action_executions) do
      modify(:on_hold_until, :utc_datetime_usec)
      add(:claim_token, :uuid)
      add(:rate_reserved, :boolean, default: false, null: false)
      add(:completed_at, :utc_datetime_usec)
    end

    create table(:dispatch_portals, primary_key: false) do
      add(:portal_id, :bigint, primary_key: true)
      add(:claim_token, :uuid)
      add(:lease_until, :utc_datetime_usec)

      add(:available_at, :utc_datetime_usec,
        null: false,
        default: fragment("timezone('UTC', clock_timestamp())")
      )
    end

    create table(:dispatch_queues, primary_key: false) do
      add(:queue_id, :text, primary_key: true)

      add(:portal_id, references(:dispatch_portals, column: :portal_id, type: :bigint),
        null: false
      )

      add(:max_throughput, :integer, null: false)
      add(:interval_ms, :bigint, null: false)
      add(:next_run_at, :utc_datetime_usec, null: false)
      add(:budget_remaining, :integer, null: false, default: 0)
      add(:budget_through_id, :bigint, null: false, default: 0)
    end

    create(index(:dispatch_queues, [:portal_id]))

    create(
      constraint(:dispatch_queues, :positive_rate,
        check:
          "max_throughput > 0 AND max_throughput <= 10000 AND interval_ms > 0 AND interval_ms <= 2419200000 AND budget_remaining >= 0"
      )
    )

    flush()

    # Historical updates did not timestamp completions. Conservatively wait a
    # full interval for legacy queues; never invent a last-dispatch timestamp.
    execute("""
    INSERT INTO dispatch_portals (portal_id)
    SELECT DISTINCT split_part(queue_id, ':', 2)::bigint FROM action_executions
    WHERE queue_id ~ '^queue:[0-9]+:[^:]+:[^:]+:[^:]+$'
    ON CONFLICT DO NOTHING
    """)

    execute("""
    INSERT INTO dispatch_queues (queue_id, portal_id, max_throughput, interval_ms, next_run_at)
    SELECT queue_id, split_part(queue_id, ':', 2)::bigint, max_throughput::integer,
      time::bigint * unit_ms, timezone('UTC', clock_timestamp()) + time::bigint * unit_ms * interval '1 millisecond'
    FROM (
      SELECT DISTINCT ON (queue_id) queue_id, max_throughput, time,
        CASE period WHEN 'second' THEN 1000 WHEN 'seconds' THEN 1000
          WHEN 'minute' THEN 60000 WHEN 'minutes' THEN 60000
          WHEN 'hour' THEN 3600000 WHEN 'hours' THEN 3600000
          WHEN 'day' THEN 86400000 WHEN 'days' THEN 86400000 END AS unit_ms
      FROM action_executions WHERE queue_id ~ '^queue:[0-9]+:[^:]+:[^:]+:[^:]+$'
      ORDER BY queue_id, id DESC
    ) latest
    WHERE max_throughput ~ '^[0-9]+$' AND time ~ '^[0-9]+$' AND unit_ms IS NOT NULL
    ON CONFLICT DO NOTHING
    """)

    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM action_executions a
        LEFT JOIN dispatch_queues q ON q.queue_id = a.queue_id
        WHERE NOT a.processed AND NOT a.permanently_failed AND q.queue_id IS NULL) THEN
        RAISE EXCEPTION 'Active work has no valid durable queue: repair before cutover';
      END IF;
    END $$;
    """)

    execute(
      "UPDATE action_executions SET on_hold_until = NULL WHERE last_failure_reason = 'in_flight' AND NOT processed"
    )

    execute("""
    UPDATE oban_jobs SET state='cancelled', cancelled_at=timezone('UTC',clock_timestamp())
    WHERE worker='Throttle.ThrottleWorker' AND state IN ('available','scheduled','executing','retryable')
    """)
  end

  def down do
    raise "Dispatch cutover is forward-only. Roll back the application using the documented paused-dispatch procedure; restore a verified backup for schema rollback."
  end
end
