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
  # Covers four 30-second callback attempts, retry sleeps, and a token refresh.
  # A claim must outlive the entire HTTP path or another instance may send the
  # same callback while the first request is still running.
  @claim_lease_seconds 180

  def claim_lease_seconds, do: @claim_lease_seconds

  def renew_claims([]), do: {0, nil}

  def renew_claims(action_ids) when is_list(action_ids) do
    lease_until =
      DateTime.utc_now()
      |> DateTime.add(@claim_lease_seconds, :second)
      |> DateTime.truncate(:second)

    from(a in ActionExecution,
      where: a.id in ^action_ids,
      where: not a.processed and not a.permanently_failed,
      where: a.last_failure_reason == "in_flight",
      update: [
        set: [
          on_hold_until:
            fragment(
              "CASE WHEN on_hold_until IS NULL OR on_hold_until < ? THEN ? ELSE on_hold_until END",
              ^lease_until,
              ^lease_until
            )
        ]
      ]
    )
    |> Repo.update_all([])
  end

  def processable_action_ids([]), do: MapSet.new()

  def processable_action_ids(action_ids) when is_list(action_ids) do
    now = DateTime.utc_now()

    from(a in ActionExecution,
      where: a.id in ^action_ids,
      where: not a.processed and not a.permanently_failed,
      where: is_nil(a.expires_at) or a.expires_at > ^now,
      select: a.id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  def get_next_action_batch(queue_id, max_throughput, exclude_ids \\ []) do
    throughput = safe_to_integer(max_throughput, 10)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    lease_until = DateTime.add(now, @claim_lease_seconds, :second)

    query =
      from(a in ActionExecution,
        where: a.queue_id == ^queue_id and not a.processed and not a.permanently_failed,
        where: is_nil(a.on_hold_until) or a.on_hold_until <= ^now,
        where: is_nil(a.expires_at) or a.expires_at > ^now,
        where: a.id not in ^exclude_ids,
        order_by: [asc: a.inserted_at],
        limit: ^throughput,
        lock: "FOR UPDATE SKIP LOCKED"
      )

    case Repo.transaction(fn ->
           executions = Repo.all(query)
           action_ids = Enum.map(executions, & &1.id)

           if action_ids != [] do
             from(a in ActionExecution, where: a.id in ^action_ids)
             |> Repo.update_all(
               set: [last_failure_reason: "in_flight", on_hold_until: lease_until]
             )
           end

           executions
         end) do
      {:ok, executions} -> {:ok, executions}
      {:error, reason} -> {:error, reason}
    end
  end

  def latest_queue_config(queue_id) do
    now = DateTime.utc_now()

    query =
      from(a in ActionExecution,
        where: a.queue_id == ^queue_id and not a.processed and not a.permanently_failed,
        where: is_nil(a.expires_at) or a.expires_at > ^now,
        order_by: [desc: a.id],
        select: %{
          config_id: a.id,
          queue_id: a.queue_id,
          max_throughput: a.max_throughput,
          time: a.time,
          period: a.period
        },
        limit: 1
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      config -> {:ok, config}
    end
  end

  def runnable_queue_configs do
    now = DateTime.utc_now()

    active =
      from(a in ActionExecution,
        where: not a.processed and not a.permanently_failed,
        where: is_nil(a.expires_at) or a.expires_at > ^now
      )

    runnable =
      from(a in subquery(active),
        where: is_nil(a.on_hold_until) or a.on_hold_until <= ^now
      )

    runnable_queue_ids =
      from(a in subquery(runnable),
        distinct: a.queue_id,
        select: %{queue_id: a.queue_id}
      )

    counts =
      from(a in subquery(active),
        group_by: a.queue_id,
        select: %{queue_id: a.queue_id, backlog_size: count(a.id)}
      )

    latest =
      from(a in subquery(active),
        distinct: a.queue_id,
        order_by: [asc: a.queue_id, desc: a.id],
        select: %{
          config_id: a.id,
          queue_id: a.queue_id,
          max_throughput: a.max_throughput,
          time: a.time,
          period: a.period
        }
      )

    from(counts in subquery(counts),
      join: latest in subquery(latest),
      on: latest.queue_id == counts.queue_id,
      join: runnable_queue in subquery(runnable_queue_ids),
      on: runnable_queue.queue_id == counts.queue_id,
      select: %{
        config_id: latest.config_id,
        queue_id: latest.queue_id,
        max_throughput: latest.max_throughput,
        time: latest.time,
        period: latest.period,
        backlog_size: counts.backlog_size
      }
    )
    |> Repo.all()
  end

  def defer_rate_limited_actions(action_ids, retry_after_seconds)
      when is_integer(retry_after_seconds) and retry_after_seconds >= 0 do
    # PortalQueue owns an in-memory retry timer. Keep the database lease for a
    # complete processing window after that timer fires so rolling instances
    # cannot claim the same callbacks during the retry request.
    hold_until =
      DateTime.utc_now()
      |> DateTime.add(retry_after_seconds + @claim_lease_seconds, :second)
      |> DateTime.truncate(:second)

    from(a in ActionExecution,
      where: a.id in ^action_ids,
      update: [
        set: [
          last_failure_reason: "rate_limited",
          on_hold_until:
            fragment(
              "CASE WHEN on_hold_until IS NULL OR on_hold_until < ? THEN ? ELSE on_hold_until END",
              ^hold_until,
              ^hold_until
            )
        ]
      ]
    )
    |> Repo.update_all([])
  end

  def expire_overdue_actions do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(a in ActionExecution,
      where: not a.processed and not a.permanently_failed,
      where: not is_nil(a.expires_at) and a.expires_at <= ^now
    )
    |> Repo.update_all(
      set: [
        permanently_failed: true,
        last_failure_reason: "hubspot_block_expired",
        on_hold_until: nil
      ]
    )
  end

  def queue_active?(queue_id) do
    Logger.debug("Checking if queue #{queue_id} is active")
    now = DateTime.utc_now()

    query =
      from(a in ActionExecution,
        where: a.queue_id == ^queue_id,
        where: not a.processed and not a.permanently_failed,
        where: is_nil(a.expires_at) or a.expires_at > ^now,
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

  def mark_callbacks_processed_and_clear_errors(callback_ids) do
    {_count, _} =
      from(a in ActionExecution,
        where: a.callback_id in ^callback_ids and not a.processed
      )
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

  defp safe_to_integer(value, _default) when is_integer(value), do: value

  defp safe_to_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  defp safe_to_integer(_value, default), do: default
end
