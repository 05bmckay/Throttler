defmodule Throttle.PortalQueue do
  use GenServer
  require Logger
  alias Throttle.OAuthManager
  alias Throttle.ActionQueries

  @flush_interval 900
  @max_batch_size 100
  @max_queue_size 10_000
  # Queued rows are leased for claim_lease_seconds (180s). Renew only the ones
  # that have waited long enough to matter; a queue that drains quickly never
  # touches the database for renewal at all.
  @renew_after_ms 60_000

  ## Client API

  def start_link(portal_id) do
    GenServer.start_link(__MODULE__, portal_id, name: via_tuple(portal_id))
  end

  def enqueue_executions(server, executions, owner \\ nil)

  def enqueue_executions(pid, executions, owner) when is_pid(pid) do
    GenServer.cast(pid, {:enqueue, executions, owner})
  end

  def enqueue_executions(portal_id, executions, owner) do
    GenServer.cast(via_tuple(portal_id), {:enqueue, executions, owner})
  end

  ## Server Callbacks

  def init(portal_id) do
    state = %{
      portal_id: portal_id,
      queue: :queue.new(),
      timer_ref: nil,
      rate_limited_until: nil
    }

    {:ok, state}
  end

  def handle_cast({:enqueue, executions, owner}, state) do
    now = System.monotonic_time(:millisecond)
    items = Enum.map(executions, &{&1, owner, now})
    {:noreply, enqueue_batch(state, items)}
  end

  def handle_info(:flush, state) do
    {:noreply, flush_now(%{state | timer_ref: nil})}
  end

  ## Helper Functions

  defp via_tuple(portal_id) do
    {:via, Registry, {Throttle.PortalRegistry, portal_id}}
  end

  defp schedule_flush(state, delay_ms) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    timer_ref = Process.send_after(self(), :flush, max(delay_ms, 0))
    %{state | timer_ref: timer_ref}
  end

  defp maybe_schedule_flush(%{timer_ref: nil} = state) do
    schedule_flush(state, @flush_interval)
  end

  defp maybe_schedule_flush(state), do: state

  defp schedule_if_pending(state) do
    if :queue.is_empty(state.queue), do: state, else: maybe_schedule_flush(state)
  end

  defp rate_limit_remaining_ms(%{rate_limited_until: nil}, _now), do: 0

  defp rate_limit_remaining_ms(%{rate_limited_until: until}, now), do: max(until - now, 0)

  # Flush unless a Retry-After window is open, in which case one flush is
  # armed for when it closes. Rate-limited batches re-enter the queue, so a
  # single paced flush loop drains them instead of several concurrent retries.
  defp flush_now(state) do
    now = System.monotonic_time(:millisecond)

    case rate_limit_remaining_ms(state, now) do
      0 ->
        %{state | rate_limited_until: nil}
        |> flush_queue()
        |> Map.put(:timer_ref, nil)
        |> schedule_if_pending()

      remaining_ms ->
        schedule_flush(state, remaining_ms)
    end
  end

  defp enqueue_batch(state, items) do
    current_len = :queue.len(state.queue)

    if current_len + length(items) > @max_queue_size do
      Logger.warning(
        "PortalQueue for portal #{state.portal_id} at capacity (#{current_len}/#{@max_queue_size}), rejecting #{length(items)} executions"
      )

      action_ids = action_ids(items)
      ActionQueries.handle_batch_failure(action_ids, "queue_overflow")
      notify_delivery_complete(items)
      state
    else
      was_idle = current_len == 0 and is_nil(state.timer_ref)

      new_queue =
        Enum.reduce(items, state.queue, fn item, queue ->
          :queue.in(item, queue)
        end)

      state = %{state | queue: new_queue}

      cond do
        # An idle queue delivers immediately. QueueRunner waits for this batch
        # before claiming the next one, so holding a lone batch for the full
        # flush interval would cut every per-second queue's effective rate.
        was_idle -> flush_now(state)
        :queue.len(new_queue) >= @max_batch_size -> flush_now(state)
        true -> maybe_schedule_flush(state)
      end
    end
  end

  defp flush_queue(state) do
    now = System.monotonic_time(:millisecond)
    state = %{state | queue: renew_stale_leases(state.queue, state.portal_id, now)}
    {batch, new_queue} = dequeue_batch(state.queue)
    state = %{state | queue: new_queue}

    if batch != [] do
      dispatch_batch(state, batch)
    else
      state
    end
  end

  # A queued item must remain leased until PortalQueue has actually attempted
  # delivery. Only items that have waited @renew_after_ms are renewed, and a
  # database error here is logged rather than allowed to crash the queue and
  # drop every buffered batch for the portal.
  defp renew_stale_leases(queue, portal_id, now) do
    items = :queue.to_list(queue)

    stale_ids =
      for {execution, _owner, queued_at} <- items, now - queued_at >= @renew_after_ms do
        execution.id
      end

    if stale_ids == [] do
      queue
    else
      try do
        ActionQueries.renew_claims(stale_ids)

        items
        |> Enum.map(fn
          {execution, owner, queued_at} when now - queued_at >= @renew_after_ms ->
            {execution, owner, now}

          item ->
            item
        end)
        |> :queue.from_list()
      rescue
        e ->
          Logger.error(
            "PortalQueue for portal #{portal_id} could not renew #{length(stale_ids)} leases: #{Exception.message(e)}"
          )

          queue
      end
    end
  end

  defp dequeue_batch(queue) do
    Logger.debug("Queue before dequeuing: #{inspect(queue)}")
    {batch, remaining_queue} = dequeue_batch_elements(queue, @max_batch_size, [])
    {Enum.reverse(batch), remaining_queue}
  end

  defp dequeue_batch_elements(queue, 0, acc) do
    {acc, queue}
  end

  defp dequeue_batch_elements(queue, n, acc) do
    case :queue.out(queue) do
      {{:value, item}, queue_tail} ->
        dequeue_batch_elements(queue_tail, n - 1, [item | acc])

      {:empty, _} ->
        {acc, queue}
    end
  end

  defp dispatch_batch(state, items) do
    executions = Enum.map(items, &elem(&1, 0))
    processable_ids = executions |> action_ids() |> ActionQueries.processable_action_ids()

    {processable_items, stale_items} =
      Enum.split_with(items, fn {execution, _owner, _queued_at} ->
        MapSet.member?(processable_ids, execution.id)
      end)

    notify_delivery_complete(stale_items)

    if processable_items == [] do
      state
    else
      case send_batch(state.portal_id, Enum.map(processable_items, &elem(&1, 0))) do
        :done ->
          notify_delivery_complete(processable_items)
          state

        {:retry, retry_after} ->
          requeue_rate_limited(state, processable_items, retry_after)
      end
    end
  end

  # Put the batch back at the head of the queue and hold every flush until the
  # Retry-After window closes. The rows were already deferred in the database.
  defp requeue_rate_limited(state, items, retry_after) do
    now = System.monotonic_time(:millisecond)
    retry_ms = retry_after * 1_000
    refreshed = Enum.map(items, fn {execution, owner, _queued_at} -> {execution, owner, now} end)

    %{
      state
      | queue: :queue.join(:queue.from_list(refreshed), state.queue),
        rate_limited_until: now + retry_ms
    }
    |> schedule_flush(retry_ms)
  end

  defp send_batch(portal_id, executions) do
    Logger.info("Sending batch for portal #{portal_id} with #{length(executions)} executions")
    action_ids = Enum.map(executions, & &1.id)

    case OAuthManager.get_token(portal_id) do
      {:ok, token} ->
        handle_delivery_result(
          process_with_token(executions, token),
          portal_id,
          executions,
          action_ids,
          true
        )

      {:error, reason} ->
        Logger.error("Error getting token for portal #{portal_id}: #{inspect(reason)}")
        ActionQueries.handle_batch_failure(action_ids, "token_error")
        :done
    end
  end

  defp handle_delivery_result(:ok, _portal_id, _executions, _action_ids, _allow_refresh),
    do: :done

  defp handle_delivery_result(
         {:error, :unauthorized},
         portal_id,
         executions,
         action_ids,
         true
       ) do
    Logger.warning("Token expired for portal #{portal_id}, refreshing and retrying once")

    case OAuthManager.force_refresh_token(portal_id) do
      {:ok, new_token} ->
        # The first attempt may have consumed most of the lease through HTTP
        # retries. Renew before the second full send so another instance
        # cannot claim these rows mid-delivery.
        ActionQueries.renew_claims(action_ids)

        handle_delivery_result(
          process_with_token(executions, new_token),
          portal_id,
          executions,
          action_ids,
          false
        )

      {:error, refresh_reason} ->
        ActionQueries.handle_batch_failure(
          action_ids,
          "token_refresh_failed: #{inspect(refresh_reason)}"
        )

        :done
    end
  end

  defp handle_delivery_result(
         {:error, {:rate_limited, retry_after}},
         portal_id,
         executions,
         action_ids,
         _allow_refresh
       ) do
    Logger.warning(
      "Batch rate limited for portal #{portal_id}, retrying #{length(executions)} executions in #{retry_after}s"
    )

    ActionQueries.defer_rate_limited_actions(action_ids, retry_after)
    {:retry, retry_after}
  end

  defp handle_delivery_result(
         {:error, reason},
         portal_id,
         _executions,
         action_ids,
         _allow_refresh
       ) do
    Logger.error("Error processing batch for portal #{portal_id}: #{inspect(reason)}")
    ActionQueries.handle_batch_failure(action_ids, inspect(reason))
    :done
  end

  defp action_ids(items) do
    Enum.map(items, fn
      {%{id: id}, _owner, _queued_at} -> id
      %{id: id} -> id
    end)
  end

  defp notify_delivery_complete(items) do
    items
    |> Enum.group_by(fn {_execution, owner, _queued_at} -> owner end, fn {execution, _owner, _} ->
      execution.id
    end)
    |> Enum.each(fn
      {owner, ids} when is_pid(owner) -> send(owner, {:portal_delivery_complete, ids})
      {_owner, _ids} -> :ok
    end)
  end

  defp process_with_token(executions, token) do
    case Throttle.ThrottleWorker.process_with_token(executions, token) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
