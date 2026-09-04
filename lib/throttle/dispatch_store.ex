defmodule Throttle.DispatchStore do
  @moduledoc "Postgres owns rate reservations, portal exclusion, retries and callback claims."
  alias Throttle.Repo
  alias Throttle.Schemas.ActionExecution
  import Ecto.Query

  @lease_seconds 180
  def lease_seconds, do: @lease_seconds

  def ready_portals(limit) do
    Repo.query!(
      """
      SELECT p.portal_id FROM dispatch_portals p
      WHERE p.available_at <= $2 AND (p.lease_until IS NULL OR p.lease_until <= $2)
        AND EXISTS (
          SELECT 1 FROM dispatch_queues q JOIN action_executions a ON a.queue_id = q.queue_id
          WHERE q.portal_id = p.portal_id AND NOT a.processed AND NOT a.permanently_failed
            AND (a.expires_at IS NULL OR a.expires_at > $2)
            AND (a.on_hold_until IS NULL OR a.on_hold_until <= $2)
            AND (a.rate_reserved OR q.next_run_at <= $2
              OR (q.budget_remaining > 0 AND a.id <= q.budget_through_id))
        ) ORDER BY p.available_at, p.portal_id LIMIT $1
      """,
      [limit, db_now()]
    ).rows
    |> List.flatten()
  end

  def claim(portal_id) do
    Repo.transaction(fn ->
      now = db_now()

      case Repo.query!(
             """
             SELECT portal_id, CASE WHEN isolated_until > $2 THEN 1 ELSE 100 END FROM dispatch_portals WHERE portal_id = $1
               AND available_at <= $2 AND (lease_until IS NULL OR lease_until <= $2)
             FOR UPDATE SKIP LOCKED
             """,
             [portal_id, now]
           ).rows do
        [] -> nil
        [[_, limit]] -> claim_locked(portal_id, now, limit)
      end
    end)
  end

  defp claim_locked(portal_id, now, limit) do
    token = Ecto.UUID.generate()
    lease_until = DateTime.add(now, @lease_seconds, :second)

    queues =
      Repo.query!(
        """
        SELECT queue_id, max_throughput, interval_ms, next_run_at, budget_remaining, budget_through_id
        FROM dispatch_queues q WHERE portal_id = $1 AND EXISTS (
          SELECT 1 FROM action_executions a WHERE a.queue_id = q.queue_id
            AND NOT a.processed AND NOT a.permanently_failed
            AND (a.expires_at IS NULL OR a.expires_at > $2)
            AND (a.on_hold_until IS NULL OR a.on_hold_until <= $2)
            AND (a.rate_reserved OR q.next_run_at <= $2
              OR (q.budget_remaining > 0 AND a.id <= q.budget_through_id))
        ) ORDER BY next_run_at, queue_id LIMIT 100 FOR UPDATE
        """,
        [portal_id, now]
      ).rows

    actions =
      Enum.reduce_while(queues, [], fn queue, acc ->
        remaining = limit - length(acc)

        if remaining == 0,
          do: {:halt, acc},
          else: {:cont, acc ++ claim_queue(queue, remaining, token, lease_until, now)}
      end)

    if actions == [] do
      nil
    else
      Repo.query!(
        "UPDATE dispatch_portals SET claim_token=$2, lease_until=$3 WHERE portal_id=$1",
        [portal_id, Ecto.UUID.dump!(token), lease_until]
      )

      %{portal_id: portal_id, token: token, actions: actions, lease_until: lease_until}
    end
  end

  defp claim_queue(
         [queue_id, throughput, interval, next_run, budget, cutoff],
         capacity,
         token,
         lease,
         now
       ) do
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

    {budget, cutoff} =
      if room > 0 and DateTime.compare(DateTime.from_naive!(next_run, "Etc/UTC"), now) != :gt do
        ids =
          Repo.all(
            from a in base,
              where: not a.rate_reserved,
              order_by: [a.inserted_at, a.id],
              limit: ^throughput,
              select: a.id
          )

        if ids == [] do
          {0, 0}
        else
          next_run = DateTime.add(now, interval, :millisecond)

          Repo.query!(
            "UPDATE dispatch_queues SET next_run_at=$2, budget_remaining=$3, budget_through_id=$4 WHERE queue_id=$1",
            [queue_id, next_run, length(ids), Enum.max(ids)]
          )

          {length(ids), Enum.max(ids)}
        end
      else
        {budget, cutoff}
      end

    fresh_limit = min(room, budget)

    fresh =
      if fresh_limit > 0 do
        Repo.all(
          from a in base,
            where: not a.rate_reserved and a.id <= ^cutoff,
            order_by: [a.inserted_at, a.id],
            limit: ^fresh_limit,
            lock: "FOR UPDATE SKIP LOCKED"
        )
      else
        []
      end

    if fresh != [] do
      Repo.query!(
        "UPDATE dispatch_queues SET budget_remaining=GREATEST(budget_remaining-$2,0) WHERE queue_id=$1",
        [queue_id, length(fresh)]
      )
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
      # Lock the portal first in every transition. Late results from replaced
      # tasks cannot release the new owner's portal or mutate its actions.
      owned =
        Repo.query!(
          """
          SELECT portal_id FROM dispatch_portals
          WHERE portal_id=$1 AND claim_token=$2 AND lease_until > $3 FOR UPDATE
          """,
          [batch.portal_id, Ecto.UUID.dump!(batch.token), now]
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
          [batch.portal_id, DateTime.add(now, 300, :second)]
        )
      end

      retry_at = apply_result(query, result, now)

      Repo.query!(
        """
        UPDATE dispatch_portals SET claim_token=NULL, lease_until=NULL, available_at=$2
        WHERE portal_id=$1
        """,
        [batch.portal_id, retry_at]
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

    now
  end

  defp apply_result(query, {:rate_limited, seconds}, now) do
    until = DateTime.add(now, max(seconds, 1), :second)

    Repo.update_all(query,
      set: [claim_token: nil, on_hold_until: until, last_failure_reason: "rate_limited"]
    )

    until
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

    now
  end

  defp apply_result(query, {:isolate, reason}, now),
    do: apply_result(query, {:retry, reason}, now)

  defp apply_result(query, {:retry, reason}, now) do
    # A retry consumes its original rate reservation, never fresh queue quota.
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
              fragment("CASE WHEN total_attempts + 1 >= 20 THEN ? ELSE completed_at END", ^now),
            on_hold_until:
              fragment(
                "?::timestamp + LEAST(1800, 2 * power(2, LEAST(total_attempts, 10))) * interval '1 second'",
                ^now
              )
          ]
        ]
      ),
      []
    )

    now
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
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end
end
