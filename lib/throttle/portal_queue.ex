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

  def enqueue_executions(portal_id, executions) do
    GenServer.cast(via_tuple(portal_id), {:enqueue, executions})
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

  def handle_cast({:enqueue, executions}, state) do
    {:noreply, enqueue_batch(state, executions)}
  end

  def handle_info(:flush, state) do
    state = state |> flush_queue() |> Map.put(:timer_ref, nil) |> schedule_if_pending()
    {:noreply, state}
  end

  def handle_info({:retry_batch, executions}, state) do
    {:noreply, enqueue_batch(state, executions)}
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

  defp enqueue_batch(state, executions) do
    current_len = :queue.len(state.queue)

    if current_len + length(executions) > @max_queue_size do
      Logger.warning(
        "PortalQueue for portal #{state.portal_id} at capacity (#{current_len}/#{@max_queue_size}), rejecting #{length(executions)} executions"
      )

      action_ids = Enum.map(executions, & &1.id)
      ActionQueries.handle_batch_failure(action_ids, "queue_overflow")
      state
    else
      new_queue =
        Enum.reduce(executions, state.queue, fn execution, queue ->
          :queue.in(execution, queue)
        end)

      state
      |> Map.put(:queue, new_queue)
      |> maybe_schedule_flush()
      |> maybe_flush()
    end
  end

  defp flush_queue(state) do
    {batch, new_queue} = dequeue_batch(state.queue)

    if batch != [] do
      send_batch(state.portal_id, batch)
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

  defp send_batch(portal_id, executions) do
    Logger.info("Sending batch for portal #{portal_id} with #{length(executions)} executions")
    action_ids = Enum.map(executions, & &1.id)

    case OAuthManager.get_token(portal_id) do
      {:ok, token} ->
        case process_with_token(executions, token) do
          :ok ->
            :ok

          {:error, :unauthorized} ->
            Logger.warning("Token expired for portal #{portal_id}, refreshing and retrying once")

            case OAuthManager.force_refresh_token(portal_id) do
              {:ok, new_token} ->
                case process_with_token(executions, new_token) do
                  :ok ->
                    :ok

                  {:error, retry_reason} ->
                    ActionQueries.handle_batch_failure(action_ids, inspect(retry_reason))
                end

              {:error, refresh_reason} ->
                ActionQueries.handle_batch_failure(
                  action_ids,
                  "token_refresh_failed: #{inspect(refresh_reason)}"
                )
            end

          {:error, {:rate_limited, retry_after}} ->
            Logger.warning(
              "Batch rate limited for portal #{portal_id}, retrying #{length(executions)} executions in #{retry_after}s"
            )

            ActionQueries.defer_rate_limited_actions(action_ids, retry_after)
            Process.send_after(self(), {:retry_batch, executions}, retry_after * 1_000)

          {:error, reason} ->
            Logger.error("Error processing batch for portal #{portal_id}: #{inspect(reason)}")
            ActionQueries.handle_batch_failure(action_ids, inspect(reason))
        end

      {:error, reason} ->
        Logger.error("Error getting token for portal #{portal_id}: #{inspect(reason)}")
        ActionQueries.handle_batch_failure(action_ids, "token_error")
    end
  end

  defp process_with_token(executions, token) do
    case Throttle.ThrottleWorker.process_with_token(executions, token) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
