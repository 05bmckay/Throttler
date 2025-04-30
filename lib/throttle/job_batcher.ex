defmodule Throttle.JobBatcher do
  @moduledoc """
  A GenServer responsible for batching Oban job insertions.

  It collects jobs received via `cast` and inserts them in batches
  using `Oban.insert_all/2` either when a batch size limit is reached
  or a timeout occurs.
  """
  use GenServer

  require Logger

  @default_batch_size 100
  @default_flush_interval_ms 50 # 50 milliseconds
  @max_retry_attempts 3
  @initial_retry_delay_ms 100

  # Client API

  @doc """
  Starts the JobBatcher GenServer.
  """
  def start_link(opts) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    flush_interval = Keyword.get(opts, :flush_interval_ms, @default_flush_interval_ms)
    GenServer.start_link(__MODULE__, %{batch_size: batch_size, flush_interval: flush_interval}, name: __MODULE__)
  end

  @doc """
  Sends a job changeset to be batched and inserted later.
  """
  def queue_job(oban_changeset) do
    GenServer.cast(__MODULE__, {:queue, oban_changeset})
  end

  # Server Callbacks

  @impl true
  def init(config) do
    Logger.info("Starting JobBatcher with batch_size=#{config.batch_size}, flush_interval=#{config.flush_interval}ms")
    state = %{
      jobs: [],
      timer_ref: nil,
      batch_size: config.batch_size,
      flush_interval: config.flush_interval
    }
    {:ok, state}
  end

  @impl true
  def handle_cast({:queue, job_changeset}, state) do
    new_jobs = [job_changeset | state.jobs]
    new_state = %{state | jobs: new_jobs}

    if Enum.count(new_jobs) >= state.batch_size do
      flush_jobs(new_state)
    else
      # Start timer only if it's not already running and there are jobs
      new_state_with_timer =
        if is_nil(state.timer_ref) and Enum.any?(new_jobs) do
           schedule_flush(new_state)
        else
           new_state
        end
      {:noreply, new_state_with_timer}
    end
  end

  @impl true
  def handle_info(:flush, state) do
    flush_jobs(%{state | timer_ref: nil}) # Clear timer ref before flushing
  end

  @impl true
  def handle_info({:retry_batch, failed_changesets, attempt}, state) do
    Logger.info("Retrying job batch insertion, attempt ##{attempt}")
    attempt_insert(failed_changesets, attempt, state)
  end

  # Catch-all for unexpected messages
  @impl true
  def handle_info(msg, state) do
    Logger.warning("JobBatcher received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # --- Private Helpers ---

  defp schedule_flush(state) do
     timer_ref = Process.send_after(self(), :flush, state.flush_interval)
     %{state | timer_ref: timer_ref}
  end

  defp cancel_flush_timer(state) do
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end
    %{state | timer_ref: nil}
  end

  defp flush_jobs(state) do
    state = cancel_flush_timer(state)

    if Enum.empty?(state.jobs) do
      {:noreply, state} # Nothing to flush
    else
      # Jobs are added head first, so reverse to maintain insertion order if needed
      jobs_to_insert = Enum.reverse(state.jobs)
      # Attempt the insert, starting at attempt 0 (initial try)
      attempt_insert(jobs_to_insert, 0, %{state | jobs: []}) # Clear buffer immediately
    end
  end

  defp attempt_insert(changesets_to_insert, attempt, state) do
    case Oban.insert_all(changesets_to_insert) do
      {:ok, inserted_jobs} ->
        count = Enum.count(inserted_jobs)
        original_count = Enum.count(changesets_to_insert)
        if attempt > 0 do
          Logger.info("JobBatcher successfully inserted #{count}/#{original_count} jobs on retry attempt ##{attempt}.")
        else
          Logger.debug("JobBatcher flushed #{count} jobs successfully.")
        end
        # If some jobs didn't insert (e.g., due to `on_conflict: :nothing`), log them if needed.
        # This part depends on Oban.insert_all's behaviour with conflicts.
        if count < original_count do
           Logger.warning("JobBatcher: #{original_count - count} jobs were not inserted (possibly due to conflicts).")
        end
        {:noreply, state}

      {:error, _failed_operation, failed_changesets, _successful_jobs} ->
        failed_count = Enum.count(failed_changesets)
        Logger.error("JobBatcher failed to insert batch of #{failed_count} jobs (attempt ##{attempt + 1}).")

        if attempt < @max_retry_attempts do
          next_attempt = attempt + 1
          # Exponential backoff: 100ms, 200ms, 400ms, ...
          delay = @initial_retry_delay_ms * :math.pow(2, attempt)
          Logger.info("Scheduling retry ##{next_attempt} in #{delay}ms for #{failed_count} jobs.")
          Process.send_after(self(), {:retry_batch, failed_changesets, next_attempt}, round(delay))
          {:noreply, state}
        else
          Logger.error("JobBatcher reached max retry attempts (#{ @max_retry_attempts }) for #{failed_count} jobs. Discarding batch.")
          # Consider sending to a dead-letter queue or other mechanism here
          {:noreply, state}
        end
    end
  end
end
