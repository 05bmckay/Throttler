defmodule Throttle.PortalQueue do
  use GenServer
  require Logger
  alias Throttle.OAuthManager
  alias Throttle.ActionQueries

  @flush_interval 900
  @max_batch_size 100
  @max_queue_size 10_000

  ## Client API

  def start_link(portal_id) do
    GenServer.start_link(__MODULE__, portal_id, name: via_tuple(portal_id))
  end

  def enqueue_executions(portal_id, executions, owner \\ nil) do
    GenServer.cast(via_tuple(portal_id), {:enqueue, executions, owner})
  end

  ## Server Callbacks

  def init(portal_id) do
    state = %{
      portal_id: portal_id,
      queue: :queue.new(),
      timer_ref: nil
    }

    {:ok, state}
  end

  def handle_cast({:enqueue, executions, owner}, state) do
    items = Enum.map(executions, &{&1, owner})
    {:noreply, enqueue_batch(state, items)}
  end

  def handle_info(:flush, state) do
    state = state |> flush_queue() |> Map.put(:timer_ref, nil) |> schedule_if_pending()
    {:noreply, state}
  end

  def handle_info({:retry_batch, items}, state) do
    dispatch_batch(state.portal_id, items)
    {:noreply, schedule_if_pending(state)}
  end

  ## Helper Functions

  defp via_tuple(portal_id) do
    {:via, Registry, {Throttle.PortalRegistry, portal_id}}
  end

  defp maybe_schedule_flush(%{timer_ref: nil} = state) do
    timer_ref = Process.send_after(self(), :flush, @flush_interval)
    %{state | timer_ref: timer_ref}
  end

  defp maybe_schedule_flush(state), do: state

  defp maybe_flush(state) do
    if :queue.len(state.queue) >= @max_batch_size do
      state = flush_queue(state)

      if state.timer_ref do
        Process.cancel_timer(state.timer_ref)
      end

      state
      |> Map.put(:timer_ref, nil)
      |> schedule_if_pending()
    else
      state
    end
  end

  defp schedule_if_pending(state) do
    if :queue.is_empty(state.queue), do: state, else: maybe_schedule_flush(state)
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
      new_queue =
        Enum.reduce(items, state.queue, fn item, queue ->
          :queue.in(item, queue)
        end)

      state
      |> Map.put(:queue, new_queue)
      |> maybe_schedule_flush()
      |> maybe_flush()
    end
  end

  defp flush_queue(state) do
    # A queued item must remain leased until PortalQueue has actually attempted
    # delivery. Renewing the small, bounded portal queue prevents QueueRunner
    # from reclaiming the same rows while they are waiting behind another batch.
    state.queue
    |> :queue.to_list()
    |> action_ids()
    |> ActionQueries.renew_claims()

    {batch, new_queue} = dequeue_batch(state.queue)

    if batch != [] do
      dispatch_batch(state.portal_id, batch)
    end

    %{state | queue: new_queue}
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

  defp dispatch_batch(portal_id, items) do
    executions = Enum.map(items, &elem(&1, 0))
    processable_ids = executions |> action_ids() |> ActionQueries.processable_action_ids()

    {processable_items, stale_items} =
      Enum.split_with(items, fn {execution, _owner} ->
        MapSet.member?(processable_ids, execution.id)
      end)

    notify_delivery_complete(stale_items)

    if processable_items != [] do
      processable_items
      |> action_ids()
      |> ActionQueries.renew_claims()

      case send_batch(portal_id, Enum.map(processable_items, &elem(&1, 0))) do
        :done ->
          notify_delivery_complete(processable_items)

        {:retry, retry_after} ->
          Process.send_after(self(), {:retry_batch, processable_items}, retry_after * 1_000)
      end
    end
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
      {%{id: id}, _owner} -> id
      %{id: id} -> id
    end)
  end

  defp notify_delivery_complete(items) do
    items
    |> Enum.group_by(fn {_execution, owner} -> owner end, fn {execution, _owner} ->
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
