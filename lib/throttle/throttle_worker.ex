defmodule Throttle.ThrottleWorker do
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      fields: [:worker, :args],
      keys: [:queue_id],
      states: [:scheduled, :available],
      period: :infinity
    ]

  require Logger
  alias Throttle.ActionQueries
  alias Throttle.HubSpotClient

  @initial_max_attempts 3
  @max_snooze_attempts 20

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(60)

  @impl Oban.Worker
  def backoff(%Oban.Job{} = job) do
    # Calculate the number of "true" failures, ignoring snoozes
    corrected_attempt = job.attempt - (job.max_attempts - @initial_max_attempts)

    # Use the default backoff calculation with the corrected attempt count
    # and ensure we use the original max_attempts for the backoff ceiling.
    Oban.Worker.backoff(%{job | attempt: corrected_attempt, max_attempts: @initial_max_attempts})
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args_map} = job) do
    # Normalize args map to use atom keys internally
    %{
      queue_id: queue_id,
      max_throughput: max_throughput,
      time: time_str,
      period: period
    } = normalize_args(args_map)

    result =
      try do
        # No need to check if active here, get_next_action_batch handles empty queues.
        case ActionQueries.get_next_action_batch(queue_id, max_throughput) do
          {:ok, []} ->
            # Queue is empty, no work done. Let the job complete normally.
            # It will be restarted later by JobCleaner or ActionBatcher if new items arrive.
            Logger.info("Queue #{queue_id} is empty, completing job.")
            :ok

          {:ok, executions} ->
            case process_executions(executions) do
              :ok ->
                # Successfully processed a batch. Decide how to proceed.
                handle_successful_batch(job, queue_id, max_throughput, time_str, period)

              {:ok, :ok} ->
                handle_successful_batch(job, queue_id, max_throughput, time_str, period)

              {:error, reason} ->
                Logger.error(
                  "Error processing executions for queue #{queue_id}: #{inspect(reason)}"
                )

                # Let Oban handle retry based on standard :error tuple
                {:error, reason}
            end

          {:error, reason} ->
            Logger.error("Error fetching batch for queue #{queue_id}: #{inspect(reason)}")
            # Let Oban handle retry
            {:error, reason}
        end
      rescue
        e ->
          stacktrace = __STACKTRACE__

          Logger.error(
            "Unexpected error processing queue #{queue_id}: #{inspect(e)}\nStacktrace: #{inspect(stacktrace)}"
          )

          # Let Oban handle retry
          {:error, :unexpected_error}
      end

    Logger.info("Job for queue #{queue_id} finishing with result: #{inspect(result)}")
    # Return :ok, {:error, ...}, or {:snooze, ...}
    result
  end

  # Helper to normalize args map keys to atoms
  defp normalize_args(%{queue_id: _} = args), do: args

  defp normalize_args(%{
         "queue_id" => queue_id,
         "max_throughput" => max_throughput,
         "time" => time,
         "period" => period
       }) do
    %{
      queue_id: queue_id,
      max_throughput: max_throughput,
      time: time,
      period: period
    }
  end

  defp handle_successful_batch(job, queue_id, max_throughput, time_str, period) do
    delay = calculate_delay(time_str, period)

    if delay <= 10 do
      # For short intervals, check if still active and snooze if necessary, respecting attempt limit
      check_active_and_snooze_or_complete(job, queue_id, max_throughput, time_str, period, delay)
    else
      # For longer intervals, schedule a new job like before
      schedule_next_job(queue_id, max_throughput, time_str, period)
      # Return :ok because scheduling the next job was successful for this one.
      :ok
    end
  end

  defp check_active_and_snooze_or_complete(job, queue_id, max_throughput, time_str, period, delay) do
    if job.attempt >= @max_snooze_attempts do
      Logger.warning(
        "Job for queue #{queue_id} reached snooze limit (#{job.attempt}). Scheduling new job."
      )

      schedule_next_job(queue_id, max_throughput, time_str, period)
      :ok
    else
      # P1-7: Only check DB every 5th snooze to reduce query load
      if rem(job.attempt, 5) == 0 do
        case ActionQueries.queue_active?(queue_id) do
          {:ok, true} ->
            {:snooze, delay}

          {:ok, false} ->
            :ok

          {:error, reason} ->
            Logger.error("Error checking queue status for #{queue_id}: #{inspect(reason)}")
            {:error, {:queue_check_failed, reason}}
        end
      else
        {:snooze, delay}
      end
    end
  end

  defp process_executions([]) do
    Logger.debug("No executions to process")
    :ok
  end

  defp process_executions(executions) do
    executions_by_portal = Enum.group_by(executions, &extract_portal_id/1)

    Enum.each(executions_by_portal, fn {portal_id, portal_executions} ->
      # Start the portal queue if not already started
      start_portal_queue(portal_id)
      # Enqueue executions into the portal queue
      Throttle.PortalQueue.enqueue_executions(portal_id, portal_executions)
    end)

    :ok
  end

  defp start_portal_queue(portal_id) do
    case Registry.lookup(Throttle.PortalRegistry, portal_id) do
      [] ->
        # Start the GenServer for the portal
        DynamicSupervisor.start_child(
          Throttle.PortalQueueSupervisor,
          {Throttle.PortalQueue, portal_id}
        )

      _ ->
        :ok
    end
  end

  def process_with_token(executions, token) do
    Logger.info("Processing with token for portal: #{token.portal_id}")

    unique_executions = Enum.uniq_by(executions, & &1.callback_id)
    action_ids = Enum.map(unique_executions, & &1.id)

    if length(unique_executions) < length(executions) do
      Logger.warning(
        "Filtered out #{length(executions) - length(unique_executions)} duplicate callback IDs"
      )
    end

    case HubSpotClient.send_batch_complete_with_retry(unique_executions, token.access_token) do
      :ok ->
        # Success: Mark processed and clear error fields
        Logger.info("Batch complete sent successfully for actions: #{inspect(action_ids)}")
        ActionQueries.mark_actions_processed_and_clear_errors(action_ids)

        # Emit telemetry event for successful action processing
        :telemetry.execute(
          [:throttle, :action, :processed],
          %{count: length(unique_executions)},
          %{portal_id: token.portal_id}
        )

        :ok

      {:error, {:http_error, 403, _body}} ->
        # Handle 403 specifically: Increment failure count, potentially put on hold
        Logger.error(
          "Batch failed with 403 Forbidden for actions: #{inspect(action_ids)}. Incrementing failure count."
        )

        ActionQueries.handle_batch_failure(action_ids, "forbidden")
        # Return specific error
        {:error, :forbidden}

      {:error, {:rate_limited, retry_after}} ->
        # Rate limited: Don't change error state, will be retried by Oban or next run
        Logger.warning(
          "Batch rate limited (429) for actions: #{inspect(action_ids)}. Will retry later."
        )

        {:error, {:rate_limited, retry_after}}

      error ->
        # Other errors: Increment failure count, potentially put on hold
        Logger.error(
          "Error sending batch complete for actions: #{inspect(action_ids)}. Error: #{inspect(error)}. Incrementing failure count."
        )

        ActionQueries.handle_batch_failure(action_ids, "other_error")
        # Return original error
        error
    end
  end

  defp extract_portal_id(execution) do
    execution.queue_id |> String.split(":") |> Enum.at(1) |> String.to_integer()
  end

  defp schedule_next_job(queue_id, max_throughput, time, period) do
    delay = calculate_delay(time, period)

    Logger.debug(
      "ThrottleWorker: Scheduling next job for queue #{queue_id} with delay: #{delay} seconds"
    )

    # Use atom keys for args to match unique keys config
    job_params = %{
      queue_id: queue_id,
      # Ensure these are strings if perform expects strings
      max_throughput: to_string(max_throughput),
      time: to_string(time),
      period: period
    }

    Oban.insert(new(job_params, schedule_in: delay))
  end

  defp calculate_delay(time, period) do
    time = String.to_integer(time)

    case period do
      "seconds" ->
        time

      "minutes" ->
        time * 60

      "hours" ->
        time * 3600

      "days" ->
        time * 86400

      _ ->
        Logger.warning("ThrottleWorker: Invalid period #{period}, defaulting to seconds")
        time
    end
  end
end
