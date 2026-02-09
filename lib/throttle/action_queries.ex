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

  @max_consecutive_failures 3
  @hold_duration_seconds 1800
  @max_total_attempts 20

  def get_next_action_batch(queue_id, max_throughput, exclude_ids \\ []) do
    throughput = safe_to_integer(max_throughput, 10)
    now = DateTime.utc_now()

    query =
      from(a in ActionExecution,
        where: a.queue_id == ^queue_id and not a.processed and not a.permanently_failed,
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

  def mark_actions_in_flight(action_ids) do
    from(a in ActionExecution, where: a.id in ^action_ids)
    |> Repo.update_all(set: [last_failure_reason: "in_flight"])
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
    max_attempts = @max_total_attempts

    from(a in ActionExecution,
      where: a.id in ^action_ids,
      update: [
        set: [
          consecutive_failures: fragment("consecutive_failures + 1"),
          total_attempts: fragment("total_attempts + 1"),
          last_failure_reason: ^reason,
          on_hold_until:
            fragment(
              "CASE WHEN consecutive_failures + 1 >= ? THEN ? ELSE on_hold_until END",
              ^threshold,
              ^hold_until
            ),
          permanently_failed:
            fragment(
              "CASE WHEN total_attempts + 1 >= ? THEN true ELSE permanently_failed END",
              ^max_attempts
            )
        ]
      ]
    )
    |> Repo.update_all([])
  end

  defp safe_to_integer(value, default) when is_integer(value), do: value

  defp safe_to_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  defp safe_to_integer(_value, default), do: default
end
