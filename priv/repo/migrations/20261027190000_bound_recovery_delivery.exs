defmodule Throttle.Repo.Migrations.BoundRecoveryDelivery do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:dispatch_queues) do
      add(:delivery_window_until, :utc_datetime_usec,
        null: false,
        default: fragment("'1970-01-01 00:00:00'::timestamp")
      )

      add(:delivery_count, :integer, null: false, default: 0)
    end

    flush()

    # Existing queues must not gain a second allowance at cutover. Preserve
    # their current next-run boundary, conservatively treating it as spent.
    # Deploy with dispatch paused; old dispatchers cannot enforce this budget.
    execute("""
    UPDATE dispatch_queues
    SET delivery_window_until=next_run_at, delivery_count=max_throughput
    """)

    create(
      constraint(:dispatch_queues, :nonnegative_delivery_count, check: "delivery_count >= 0")
    )
  end

  def down do
    raise "Forward-only delivery budget: pause dispatch and forward-fix instead of dropping state"
  end
end
