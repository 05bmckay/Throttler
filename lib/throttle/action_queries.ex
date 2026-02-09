defmodule Throttle.ActionQueries do
  @moduledoc """
  Database query operations for action executions.

  Handles fetching batches, checking queue activity, marking actions
  as processed, and recording batch failures with hold logic.
  """

  require Logger
  alias Throttle.Repo
  alias Throttle.Schemas.ActionExecution
  import Ecto.Query

  # Put actions on hold after this many consecutive failures
  @max_consecutive_failures 3
  # Hold for 30 minutes (1800 seconds)
  @hold_duration_seconds 1800

  def get_next_action_batch(queue_id, max_throughput, exclude_ids \\ []) do
    throughput = String.to_integer(max_throughput)
    now = DateTime.utc_now()

    query =
      from(a in ActionExecution,
        where: a.queue_id == ^queue_id and not a.processed,
        where: is_nil(a.on_hold_until) or a.on_hold_until <= ^now,
        where: a.id not in ^exclude_ids,
        order_by: [asc: a.inserted_at],
        limit: ^throughput
      )

    case Repo.all(query) do
      [] ->
        {:ok, []}

      executions ->
        {:ok, executions}
    end
  end

  def queue_active?(queue_id) do
    Logger.debug("Checking if queue #{queue_id} is active")

    query =
      from(a in ActionExecution,
        where: a.queue_id == ^queue_id,
        where: not a.processed,
        order_by: [desc: a.inserted_at],
        select: a.inserted_at,
        limit: 1
      )

    case Repo.one(query) do
      nil ->
        Logger.debug("No active executions found for queue #{queue_id}")
        {:ok, false}

      _ ->
        Logger.debug("Active executions found for queue #{queue_id}")
        {:ok, true}
    end
  end

  def mark_actions_processed_and_clear_errors(action_ids) do
    {_count, _} =
      from(a in ActionExecution, where: a.id in ^action_ids)
      |> Repo.update_all(
        set: [
          processed: true,
          last_failure_reason: nil,
          consecutive_failures: 0,
          on_hold_until: nil
        ]
      )
  end

  def handle_batch_failure(action_ids, reason) do
    hold_until = DateTime.add(DateTime.utc_now(), @hold_duration_seconds, :second)
    threshold = @max_consecutive_failures

    from(a in ActionExecution,
      where: a.id in ^action_ids,
      update: [
        set: [
          consecutive_failures: fragment("consecutive_failures + 1"),
          last_failure_reason: ^reason,
          on_hold_until:
            fragment(
              "CASE WHEN consecutive_failures + 1 >= ? THEN ? ELSE on_hold_until END",
              ^threshold,
              ^hold_until
            )
        ]
      ]
    )
    |> Repo.update_all([])
  end
end
