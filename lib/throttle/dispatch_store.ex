defmodule Throttle.DispatchStore do
  @moduledoc "Postgres owns rate reservations, portal exclusion, retries and callback claims."
  alias Throttle.Repo
  alias Throttle.Schemas.ActionExecution
  import Ecto.Query

  @lease_seconds 180
  def lease_seconds, do: @lease_seconds

  def ready_portals(limit, exclude_portals \\ []) do
    now_naive = db_now() |> DateTime.to_naive()

    Repo.query!(
      """
      SELECT p.portal_id FROM dispatch_portals p
      WHERE p.available_at <= $2 AND (p.lease_until IS NULL OR p.lease_until <= $2)
        AND NOT (p.portal_id = ANY($3::bigint[]))
        AND EXISTS (
          SELECT 1 FROM dispatch_queues q JOIN action_executions a ON a.queue_id = q.queue_id
          WHERE q.portal_id = p.portal_id AND NOT a.processed AND NOT a.permanently_failed
            AND (q.delivery_window_until <= $2 OR q.delivery_count < q.max_throughput)
            AND (a.expires_at IS NULL OR a.expires_at > $2)
            AND (a.on_hold_until IS NULL OR a.on_hold_until <= $2)
        ) ORDER BY p.available_at, p.portal_id LIMIT $1
      """,
      [limit, now_naive, exclude_portals]
    ).rows
    |> List.flatten()
  end

  def claim(portal_id) do
    Repo.transaction(fn ->
      now = db_now()
      now_naive = DateTime.to_naive(now)

      case Repo.query!(
             """
             SELECT portal_id, CASE WHEN isolated_until > $2 THEN 1 ELSE 100 END FROM dispatch_portals WHERE portal_id = $1
               AND available_at <= $2 AND (lease_until IS NULL OR lease_until <= $2)
             FOR UPDATE SKIP LOCKED
             """,
             [portal_id, now_naive]
           ).rows do
        [] -> nil
        [[_, limit]] -> claim_locked(portal_id, now, limit)
      end
    end)
  end

  defp claim_locked(portal_id, now, limit) do
    token = Ecto.UUID.generate()
    lease_until = DateTime.add(now, @lease_seconds, :second)
    now_naive = DateTime.to_naive(now)
    lease_naive = DateTime.to_naive(lease_until)

    queues =
      Repo.query!(
        """
        SELECT queue_id, max_throughput, interval_ms, delivery_window_until, delivery_count
        FROM dispatch_queues q WHERE portal_id = $1
          AND (delivery_window_until <= $2 OR delivery_count < max_throughput) AND EXISTS (
          SELECT 1 FROM action_executions a WHERE a.queue_id = q.queue_id
            AND NOT a.processed AND NOT a.permanently_failed
            AND (a.expires_at IS NULL OR a.expires_at > $2)
            AND (a.on_hold_until IS NULL OR a.on_hold_until <= $2)
        ) ORDER BY delivery_window_until, queue_id LIMIT 100 FOR UPDATE
        """,
        [portal_id, now_naive]
      ).rows

    {actions, queue_windows} =
      Enum.reduce_while(queues, {[], %{}}, fn queue, {acc, windows} ->
        remaining = limit - length(acc)

        if remaining == 0 do
          {:halt, {acc, windows}}
        else
          case claim_queue(queue, remaining, token, lease_until, now) do
            {[], _window_until} ->
              {:cont, {acc, windows}}

            {claimed, window_until} ->
              [queue_id | _] = queue
              {:cont, {acc ++ claimed, Map.put(windows, queue_id, window_until)}}
          end
        end
      end)

    if actions == [] do
      nil
    else
      Repo.query!(
        "UPDATE dispatch_portals SET claim_token=$2, lease_until=$3 WHERE portal_id=$1",
        [portal_id, Ecto.UUID.dump!(token), lease_naive]
      )

      %{
        portal_id: portal_id,
        token: token,
        actions: actions,
        lease_until: lease_until,
        queue_windows: queue_windows
      }
    end
  end

  defp claim_queue(
         [queue_id, throughput, interval, window_until_naive, count],
         capacity,
         token,
         lease,
         now
       ) do
    window_until = DateTime.from_naive!(window_until_naive, "Etc/UTC")

    {window_until, count} =
      if DateTime.compare(window_until, now) != :gt,
        do: {DateTime.add(now, interval, :millisecond), 0},
        else: {window_until, count}

    # One persisted per-interval burst allowance shared by retries and fresh work.
    # Fresh arrivals within an open window may use remaining unspent capacity
    # (max_throughput - delivery_count) up to the configured ceiling, while
    # retries/recoveries are always prioritized ahead of fresh work.
    capacity = min(capacity, max(throughput - count, 0))

    actions =
      if capacity > 0 do
        claim_queue_actions(queue_id, capacity, token, lease, now)
      else
        []
      end

    if actions != [] do
      window_naive = DateTime.to_naive(window_until)

      Repo.query!(
        """
        UPDATE dispatch_queues
        SET delivery_window_until=$2, delivery_count=$3,
            next_run_at=$2, budget_remaining=0, budget_through_id=0
        WHERE queue_id=$1
        """,
        [queue_id, window_naive, count + length(actions)]
      )
    end

    {actions, window_until}
  end

  defp claim_queue_actions(queue_id, capacity, token, lease, now) do
    base =
      from a in ActionExecution,
        where: a.queue_id == ^queue_id and not a.processed and not a.permanently_failed,
        where: is_nil(a.expires_at) or a.expires_at > ^now,
        where: is_nil(a.on_hold_until) or a.on_hold_until <= ^now

    retries =
      Repo.all(
        from a in base,
          where: a.rate_reserved,
          order_by: [a.inserted_at, a.id],
          limit: ^capacity,
          lock: "FOR UPDATE SKIP LOCKED"
      )

    room = capacity - length(retries)

    fresh =
      if room > 0 do
        Repo.all(
          from a in base,
            where: not a.rate_reserved,
            order_by: [a.inserted_at, a.id],
            limit: ^room,
            lock: "FOR UPDATE SKIP LOCKED"
        )
      else
        []
      end

    actions = retries ++ fresh
    ids = Enum.map(actions, & &1.id)

    if ids != [] do
      Repo.update_all(from(a in ActionExecution, where: a.id in ^ids),
        set: [
          claim_token: token,
          rate_reserved: true,
          on_hold_until: lease,
          last_failure_reason: "in_flight"
        ]
      )
    end

    actions
  end

  def owned_actions(batch) do
    now = db_now()
    ids = Enum.map(batch.actions, & &1.id)

    Repo.all(
      from a in ActionExecution,
        where: a.id in ^ids and a.claim_token == ^batch.token,
        where: not a.processed and not a.permanently_failed,
        where: a.on_hold_until > ^now,
        where: is_nil(a.expires_at) or a.expires_at > ^now,
        order_by: [a.inserted_at, a.id]
    )
  end

  def finish(batch, result) do
    Repo.transaction(fn ->
      now = db_now()
      now_naive = DateTime.to_naive(now)
      # Lock the portal first in every transition. Late results from replaced
      # tasks cannot release the new owner's portal or mutate its actions.
      owned =
        Repo.query!(
          """
          SELECT portal_id FROM dispatch_portals
          WHERE portal_id=$1 AND claim_token=$2 AND lease_until > $3 FOR UPDATE
          """,
          [batch.portal_id, Ecto.UUID.dump!(batch.token), now_naive]
        ).rows

      if owned == [], do: Repo.rollback(:stale_claim)
      ids = Enum.map(batch.actions, & &1.id)

      query =
        from a in ActionExecution,
          where: a.id in ^ids and a.claim_token == ^batch.token,
          where: not a.processed and not a.permanently_failed,
          where: is_nil(a.expires_at) or a.expires_at > ^now

      if match?({:isolate, _}, result) do
        Repo.query!(
          "UPDATE dispatch_portals SET isolated_until=$2 WHERE portal_id=$1",
          [batch.portal_id, DateTime.to_naive(DateTime.add(now, 300, :second))]
        )
      end

      {retry_at, refunded_by_queue} = apply_result(query, result, now)
      refund_delivery_counts(Map.get(batch, :queue_windows, %{}), refunded_by_queue, now_naive)

      Repo.query!(
        """
        UPDATE dispatch_portals SET claim_token=NULL, lease_until=NULL, available_at=$2
        WHERE portal_id=$1
        """,
        [batch.portal_id, DateTime.to_naive(retry_at)]
      )
    end)
  end

  defp apply_result(query, :ok, now) do
    Repo.update_all(query,
      set: [
        processed: true,
        completed_at: now,
        claim_token: nil,
        on_hold_until: nil,
        last_failure_reason: nil,
        consecutive_failures: 0
      ]
    )

    {now, %{}}
  end

  defp apply_result(query, {:rate_limited, seconds}, now) do
    until = DateTime.add(now, max(seconds, 1), :second)

    {_count, queue_ids} =
      Repo.update_all(
        from(a in query, select: a.queue_id),
        set: [claim_token: nil, on_hold_until: until, last_failure_reason: "rate_limited"]
      )

    {until, Enum.frequencies(queue_ids)}
  end

  defp apply_result(query, {:permanent, reason}, now) do
    Repo.update_all(query,
      set: [
        permanently_failed: true,
        completed_at: now,
        claim_token: nil,
        on_hold_until: nil,
        last_failure_reason: reason
      ],
      inc: [total_attempts: 1]
    )

    {now, %{}}
  end

  defp apply_result(query, {:isolate, reason}, now) do
    # Multi-item 4xx rejected the entire batch before HubSpot advanced any
    # callback. Release immediately (no backoff hold) so 1-by-1 isolation
    # completes inside the 300s isolated_until window, and refund delivery_count
    # for still-retryable rows in the same window.
    {_count, rows} =
      Repo.update_all(
        from(a in query,
          select: {a.queue_id, a.permanently_failed},
          update: [
            set: [
              claim_token: nil,
              on_hold_until: nil,
              last_failure_reason: ^reason,
              consecutive_failures: fragment("consecutive_failures + 1"),
              total_attempts: fragment("total_attempts + 1"),
              permanently_failed: fragment("total_attempts + 1 >= 20"),
              completed_at:
                fragment(
                  "CASE WHEN total_attempts + 1 >= 20 THEN ? ELSE completed_at END",
                  type(^now, :utc_datetime_usec)
                )
            ]
          ]
        ),
        []
      )

    refunded =
      rows
      |> Enum.reject(fn {_queue_id, failed} -> failed end)
      |> Enum.map(fn {queue_id, _failed} -> queue_id end)
      |> Enum.frequencies()

    {now, refunded}
  end

  defp apply_result(query, {:auth_retry, reason}, now) do
    # Definite pre-HTTP / auth rejection: HubSpot advanced zero callbacks.
    # Back off the entire portal until the earliest retryable row wakes up so
    # fresh work cannot consume refunded capacity before retries reclaim it.
    {_count, rows} =
      Repo.update_all(
        from(a in query,
          select: {a.queue_id, a.permanently_failed, a.on_hold_until},
          update: [
            set: [
              claim_token: nil,
              last_failure_reason: ^reason,
              consecutive_failures: fragment("consecutive_failures + 1"),
              total_attempts: fragment("total_attempts + 1"),
              permanently_failed: fragment("total_attempts + 1 >= 20"),
              completed_at:
                fragment(
                  "CASE WHEN total_attempts + 1 >= 20 THEN ? ELSE completed_at END",
                  type(^now, :utc_datetime_usec)
                ),
              on_hold_until:
                fragment(
                  "CASE WHEN total_attempts + 1 >= 20 THEN NULL ELSE ? + LEAST(1800, 2 * power(2, LEAST(total_attempts, 10))) * interval '1 second' END",
                  type(^now, :utc_datetime_usec)
                )
            ]
          ]
        ),
        []
      )

    retryable = Enum.reject(rows, fn {_queue_id, failed, _hold} -> failed end)

    refunded =
      retryable
      |> Enum.map(fn {queue_id, _failed, _hold} -> queue_id end)
      |> Enum.frequencies()

    retry_at =
      case retryable |> Enum.map(fn {_, _, hold} -> hold end) |> Enum.reject(&is_nil/1) do
        [] -> now
        holds -> Enum.min(holds, DateTime)
      end

    {retry_at, refunded}
  end

  defp apply_result(query, {:retry, reason}, now) do
    # Ambiguous failure: HubSpot may have already accepted the request.
    # Keep delivery_count spent so retries share the per-interval allowance.
    Repo.update_all(
      from(a in query,
        update: [
          set: [
            claim_token: nil,
            last_failure_reason: ^reason,
            consecutive_failures: fragment("consecutive_failures + 1"),
            total_attempts: fragment("total_attempts + 1"),
            permanently_failed: fragment("total_attempts + 1 >= 20"),
            completed_at:
              fragment(
                "CASE WHEN total_attempts + 1 >= 20 THEN ? ELSE completed_at END",
                type(^now, :utc_datetime_usec)
              ),
            on_hold_until:
              fragment(
                "CASE WHEN total_attempts + 1 >= 20 THEN NULL ELSE ? + LEAST(1800, 2 * power(2, LEAST(total_attempts, 10))) * interval '1 second' END",
                type(^now, :utc_datetime_usec)
              )
          ]
        ]
      ),
      []
    )

    {now, %{}}
  end

  defp refund_delivery_counts(queue_windows, refunded_by_queue, now_naive) do
    refunded_by_queue
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.each(fn {queue_id, count} ->
      with true <- count > 0,
           %DateTime{} = window_until <- Map.get(queue_windows, queue_id) do
        Repo.query!(
          """
          UPDATE dispatch_queues
          SET delivery_count = GREATEST(delivery_count - $3, 0)
          WHERE queue_id = $1 AND delivery_window_until = $2 AND delivery_window_until > $4
          """,
          [queue_id, DateTime.to_naive(window_until), count, now_naive]
        )
      end
    end)
  end

  def expire do
    now = db_now()

    Repo.update_all(
      from(a in ActionExecution,
        where: not a.processed and not a.permanently_failed,
        where: not is_nil(a.expires_at) and a.expires_at <= ^now
      ),
      set: [
        permanently_failed: true,
        completed_at: now,
        claim_token: nil,
        on_hold_until: nil,
        last_failure_reason: "hubspot_block_expired"
      ]
    )
  end

  defp db_now do
    %{rows: [[now]]} = Repo.query!("SELECT timezone('UTC', clock_timestamp())")
    DateTime.from_naive!(now, "Etc/UTC")
  end
end
