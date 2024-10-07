defmodule Throttle.PortalQueue do
  use GenServer
  require Logger
  alias Throttle.OAuthManager

  @flush_interval 1_000   # Flush after 1 second
  @max_batch_size 100     # Flush if queue reaches 100 actions

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
    new_queue = Enum.reduce(executions, state.queue, fn execution, queue ->
      :queue.in(execution, queue)
    end)
    state = %{state | queue: new_queue}
    state = maybe_schedule_flush(state)
    state = maybe_flush(state)
    {:noreply, state}
  end

  def handle_info(:flush, state) do
    state = flush_queue(state)
    {:noreply, %{state | timer_ref: nil}}
  end

  ## Helper Functions

  defp via_tuple(portal_id) do
    {:via, Registry, {Throttle.PortalRegistry, portal_id}}
  end

  defp maybe_schedule_flush(%{timer_ref: nil} = state) do
    {:ok, timer_ref} = :timer.send_after(@flush_interval, :flush)
    %{state | timer_ref: timer_ref}
  end
  defp maybe_schedule_flush(state), do: state

  defp maybe_flush(state) do
    if :queue.len(state.queue) >= @max_batch_size do
      state = flush_queue(state)
      if state.timer_ref do
        :timer.cancel(state.timer_ref)
      end
      %{state | timer_ref: nil}
    else
      state
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
    {batch_queue, remaining_queue} = :queue.split(@max_batch_size, queue)
    batch = :queue.to_list(batch_queue)
    {batch, remaining_queue}
  end

  defp send_batch(portal_id, executions) do
    Logger.info("Sending batch for portal #{portal_id} with #{length(executions)} executions")
    case OAuthManager.get_token(portal_id) do
      {:ok, token} ->
        case process_with_token(executions, token) do
          :ok -> :ok
          {:error, reason} -> Logger.error("Error processing batch: #{inspect(reason)}")
        end
      {:error, reason} ->
        Logger.error("Error getting token for portal #{portal_id}: #{inspect(reason)}")
        # Optionally handle re-queuing or error notification
    end
  end

  defp process_with_token(executions, token) do
    case Throttle.ThrottleWorker.process_with_token(executions, token) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
