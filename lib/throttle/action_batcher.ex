defmodule Throttle.ActionBatcher do
  use GenServer
  require Logger
  alias Throttle.Repo
  alias Throttle.Schemas.ActionExecution
  import Ecto.Query, only: [from: 2]

  @buffer_size 1000
  @min_flush_interval 500 # 0.5 seconds
  @max_flush_interval 5000 # 5 seconds
  @target_batch_size 50
  @max_batch_size 100

  def start_link(_opts) do
      GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
    end

  def init(_) do
    state = %{
      buffer: [],
      queues: %{},
      flush_interval: @max_flush_interval,
      timer_ref: nil
    }
    {:ok, schedule_flush(state)}
  end

  def add_action(attrs) do
      GenServer.cast(__MODULE__, {:add_action, attrs})
  end

  def handle_cast({:add_action, attrs}, state) do
    new_buffer = [attrs | state.buffer]
    if length(new_buffer) >= @buffer_size do
      {:noreply, flush_buffer(%{state | buffer: new_buffer})}
    else
      {:noreply, %{state | buffer: new_buffer}}
    end
  end

  def handle_info(:flush, state) do
    new_state = flush_buffer(state)
    {:noreply, schedule_flush(new_state)}
  end

  defp flush_buffer(state) do
    {actions_to_flush, remaining_buffer} = Enum.split(state.buffer, @buffer_size)
    new_queues = Enum.reduce(actions_to_flush, state.queues, fn action, acc ->
      Map.update(acc, action.queue_id, [action], &[action | &1])
    end)

    {final_queues, flushed_count} = process_queues(new_queues)

    new_interval = adjust_flush_interval(flushed_count, state.flush_interval)

    %{state |
      buffer: remaining_buffer,
      queues: final_queues,
      flush_interval: new_interval
    }
  end

  defp process_queues(queues) do
    Enum.reduce(queues, {%{}, 0}, fn {queue_id, actions}, {acc_queues, total_flushed} ->
      {inserted, remaining} = insert_batch(actions)
      flushed_count = length(inserted)

      if flushed_count > 0 do
        ensure_job_exists(queue_id, hd(inserted))
      end

      new_acc_queues = if length(remaining) > 0, do: Map.put(acc_queues, queue_id, remaining), else: acc_queues
      {new_acc_queues, total_flushed + flushed_count}
    end)
  end

  defp insert_batch(actions) do
    actions_to_insert = Enum.take(actions, @max_batch_size)
    prepared_actions = Enum.map(actions_to_insert, &prepare_action_for_insert/1)

    case Repo.insert_all(ActionExecution, prepared_actions, on_conflict: :nothing, returning: true) do
      {inserted_count, inserted_actions} ->
        Logger.info("Inserted #{inserted_count} actions")
        {inserted_actions, Enum.drop(actions, inserted_count)}
      error ->
        Logger.error("Batch insert failed: #{inspect(error)}")
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

  defp ensure_job_exists(queue_id, action) do
    case get_existing_job(queue_id) do
      nil ->
        Logger.info("No existing job found for queue #{queue_id}, scheduling new job")
        schedule_job(queue_id, action)
      _job ->
        Logger.info("Existing job found for queue #{queue_id}")
        :ok
    end
  end

  #TODO swap the queue_id to be a Key instead of an Arg
  defp get_existing_job(queue_id) do
      query = from(j in Oban.Job,
        where: fragment("?->>'queue_id' = ?", j.args, ^queue_id),
        where: j.state in ["scheduled", "executing"],
        order_by: [desc: j.scheduled_at],
        limit: 1
      )
      Repo.one(query)
    end


  defp schedule_job(queue_id, action) do
    job_params = %{
      queue_id: queue_id,
      max_throughput: action.max_throughput,
      time: action.time,
      period: action.period
    }

    # Use Oban's unique job feature
    uniqueness = [
      keys: [:queue_id],
      fields: [:args],
      states: [:scheduled, :available, :executing],
      period: :infinity
    ]

    changeset =
    Throttle.ThrottleWorker.new(job_params)
    |> Oban.Job.unique(uniqueness)

    case Oban.insert(changeset) do
      {:ok, job} ->
        Logger.info("Job scheduled successfully: #{inspect(job)}")
        :ok
      {:error, reason} ->
        Logger.error("Failed to schedule job: #{inspect(reason)}")
        :error
    end
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
