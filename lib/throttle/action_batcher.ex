defmodule Throttle.ActionBatcher do
  use GenServer
  require Logger
  alias Throttle.Repo
  alias Throttle.Schemas.ActionExecution
  alias Throttle.QueueRunner

  @buffer_size 1000
  # 0.5 seconds
  @min_flush_interval 500
  # 5 seconds
  @max_flush_interval 5000
  @target_batch_size 50
  @max_batch_size 100
  @max_pending_actions 20_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(_) do
    # P0-1: Trap exits so terminate/2 is called on shutdown/crash
    Process.flag(:trap_exit, true)

    state = %{
      buffer: [],
      # P1-1: O(1) size tracking instead of length/1
      buffer_size: 0,
      queues: %{},
      queued_size: 0,
      flush_interval: @max_flush_interval,
      timer_ref: nil,
      # Async flush state
      flushing: false,
      flush_task_ref: nil,
      # Track actions in-flight to prevent data loss if flush task crashes
      pending_flush: []
    }

    {:ok, schedule_flush(state)}
  end

  # P0-1: Flush remaining buffer on shutdown to prevent data loss
  # Uses synchronous flush to ensure data is saved before shutdown
  def terminate(reason, state) do
    merged_buffer = state.pending_flush ++ state.buffer
    merged_size = state.buffer_size + length(state.pending_flush)

    Logger.info(
      "ActionBatcher terminating (#{inspect(reason)}), flushing #{merged_size + state.queued_size} actions (#{state.buffer_size} buffered + #{length(state.pending_flush)} in-flight + #{state.queued_size} queued)"
    )

    if merged_size + state.queued_size > 0 do
      do_flush_sync(%{state | buffer: merged_buffer, buffer_size: merged_size})
    end

    :ok
  end

  def add_action(attrs) do
    GenServer.call(__MODULE__, {:add_action, attrs}, 5_000)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def handle_call({:add_action, _attrs}, _from, state)
      when state.buffer_size + length(state.pending_flush) + state.queued_size >=
             @max_pending_actions do
    Logger.warning(
      "ActionBatcher at capacity (#{@max_pending_actions}), rejecting action so HubSpot can retry"
    )

    {:reply, {:error, :overloaded}, state}
  end

  def handle_call({:add_action, attrs}, _from, state) do
    new_state = %{state | buffer: [attrs | state.buffer], buffer_size: state.buffer_size + 1}

    if new_state.buffer_size >= @buffer_size do
      {:reply, :ok, flush_buffer(new_state)}
    else
      {:reply, :ok, new_state}
    end
  end

  def handle_info(:flush, state) do
    new_state = flush_buffer(state)
    {:noreply, schedule_flush(new_state)}
  end

  def handle_info({ref, {flushed_count, final_queues}}, state)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    new_interval = adjust_flush_interval(flushed_count, state.flush_interval)

    :telemetry.execute(
      [:throttle, :batch, :flushed],
      %{count: flushed_count},
      %{interval: state.flush_interval}
    )

    new_state = %{
      state
      | queues: final_queues,
        queued_size: count_queued_actions(final_queues),
        flush_interval: new_interval,
        flushing: false,
        flush_task_ref: nil,
        pending_flush: []
    }

    {:noreply, new_state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    if ref == state.flush_task_ref do
      recovered_count = length(state.pending_flush)

      Logger.error(
        "Flush task crashed: #{inspect(reason)}, recovering #{recovered_count} actions back to buffer"
      )

      recovered_buffer = state.pending_flush ++ state.buffer
      recovered_size = state.buffer_size + recovered_count

      {:noreply,
       %{
         state
         | flushing: false,
           flush_task_ref: nil,
           pending_flush: [],
           buffer: recovered_buffer,
           buffer_size: recovered_size
       }}
    else
      {:noreply, state}
    end
  end

  defp flush_buffer(state) do
    if state.flushing do
      Logger.debug("Flush already in progress, skipping this cycle")
      state
    else
      {actions_to_flush, remaining_buffer} = Enum.split(state.buffer, @buffer_size)
      remaining_size = max(state.buffer_size - @buffer_size, 0)

      new_queues =
        Enum.reduce(actions_to_flush, state.queues, fn action, acc ->
          Map.update(acc, action.queue_id, [action], &[action | &1])
        end)

      task =
        Task.Supervisor.async_nolink(Throttle.FlushTaskSupervisor, fn ->
          {final_queues, flushed_count} = process_queues(new_queues)
          {flushed_count, final_queues}
        end)

      %{
        state
        | buffer: remaining_buffer,
          buffer_size: remaining_size,
          flushing: true,
          flush_task_ref: task.ref,
          pending_flush: actions_to_flush
      }
    end
  end

  defp do_flush_sync(state) do
    new_queues =
      Enum.reduce(state.buffer, state.queues, fn action, acc ->
        Map.update(acc, action.queue_id, [action], &[action | &1])
      end)

    drain_queues_sync(new_queues, 0)
  end

  defp drain_queues_sync(queues, total_flushed) when map_size(queues) == 0 do
    {total_flushed, %{}}
  end

  defp drain_queues_sync(queues, total_flushed) do
    {remaining, flushed_count} = process_queues(queues)

    cond do
      map_size(remaining) == 0 ->
        {total_flushed + flushed_count, %{}}

      flushed_count == 0 ->
        Logger.error(
          "Synchronous shutdown flush made no progress; #{count_queued_actions(remaining)} actions remain non-durable"
        )

        {total_flushed, remaining}

      true ->
        drain_queues_sync(remaining, total_flushed + flushed_count)
    end
  end

  defp count_queued_actions(queues) do
    Enum.reduce(queues, 0, fn {_queue_id, actions}, count -> count + length(actions) end)
  end

  defp process_queues(queues) do
    Enum.reduce(queues, {%{}, 0}, fn {queue_id, actions}, {acc_queues, total_flushed} ->
      {inserted, remaining} = insert_batch_and_ensure_runner(queue_id, actions)
      flushed_count = length(inserted)

      new_acc_queues =
        if remaining != [], do: Map.put(acc_queues, queue_id, remaining), else: acc_queues

      {new_acc_queues, total_flushed + flushed_count}
    end)
  end

  defp insert_batch_and_ensure_runner(queue_id, actions) do
    actions_to_insert = Enum.take(actions, @max_batch_size)
    prepared_actions = Enum.map(actions_to_insert, &prepare_action_for_insert/1)

    case Repo.transaction(fn ->
           case Repo.insert_all(ActionExecution, prepared_actions,
                  on_conflict: :nothing,
                  returning: true
                ) do
             {inserted_count, inserted_actions} ->
               Logger.info("Inserted #{inserted_count} actions")
               {inserted_actions, Enum.drop(actions, inserted_count)}

             error ->
               Logger.error("Batch insert failed: #{inspect(error)}")
               Repo.rollback({:insert_failed, error})
           end
         end) do
      {:ok, {inserted_actions, remaining}} ->
        if inserted_actions != [] do
          sample = hd(inserted_actions)

          config = %{
            max_throughput: sample.max_throughput,
            time: sample.time,
            period: sample.period
          }

          QueueRunner.ensure_started(queue_id, config)
        end

        {inserted_actions, remaining}

      {:error, reason} ->
        Logger.error("Transaction failed for queue #{queue_id}: #{inspect(reason)}")
        {[], actions}
    end
  end

  defp prepare_action_for_insert(action) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    action
    |> Map.take([:queue_id, :callback_id, :processed, :max_throughput, :time, :period])
    |> Map.put(:inserted_at, now)
    |> Map.put(:updated_at, now)
  end

  defp adjust_flush_interval(flushed_count, current_interval) do
    cond do
      flushed_count > @target_batch_size * 1.5 ->
        max(@min_flush_interval, current_interval - 500)

      flushed_count < @target_batch_size * 0.5 ->
        min(@max_flush_interval, current_interval + 500)

      true ->
        current_interval
    end
  end

  defp schedule_flush(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    timer_ref = Process.send_after(self(), :flush, state.flush_interval)
    %{state | timer_ref: timer_ref}
  end
end
