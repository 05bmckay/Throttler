defmodule Throttle.ThrottleWorker do
  use Oban.Worker, queue: :default, max_attempts: 3, unique: [keys: [:queue_id], fields: [:args], states: [:scheduled, :available], period: :infinity]
  require Logger
  alias Throttle.Repo
  alias Throttle.Schemas.ActionExecution
  import Ecto.Query

  # Store the initial configured max_attempts for the custom backoff calculation
  @initial_max_attempts 3

  @impl Oban.Worker
  def backoff(%Oban.Job{} = job) do
    # Calculate the number of "true" failures, ignoring snoozes
    corrected_attempt = job.attempt - (job.max_attempts - @initial_max_attempts)

    # Use the default backoff calculation with the corrected attempt count
    # and ensure we use the original max_attempts for the backoff ceiling.
    Oban.Worker.backoff(%{job | attempt: corrected_attempt, max_attempts: @initial_max_attempts})
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"queue_id" => queue_id, "max_throughput" => max_throughput, "time" => time_str, "period" => period}} = _job) do
    result =
      try do
        # No need to check if active here, get_next_action_batch handles empty queues.
        case get_next_action_batch(queue_id, max_throughput) do
          {:ok, []} ->
            # Queue is empty, no work done. Let the job complete normally.
            # It will be restarted later by JobCleaner or ActionBatcher if new items arrive.
            Logger.info("Queue #{queue_id} is empty, completing job.")
            :ok

          {:ok, executions} ->
            case process_executions(executions) do
              :ok ->
                # Successfully processed a batch. Decide how to proceed.
                handle_successful_batch(queue_id, max_throughput, time_str, period)
              # TODO: Revisit if {:ok, :ok} is a possible return value here and handle appropriately
              {:ok, :ok} ->
                handle_successful_batch(queue_id, max_throughput, time_str, period)
              {:error, reason} ->
                Logger.error("Error processing executions for queue #{queue_id}: #{inspect(reason)}")
                # Let Oban handle retry based on standard :error tuple
                {:error, reason}
            end

          {:error, reason} ->
            Logger.error("Error fetching batch for queue #{queue_id}: #{inspect(reason)}")
            {:error, reason} # Let Oban handle retry
        end
      rescue
        e ->
          stacktrace = System.stacktrace()
          Logger.error("Unexpected error processing queue #{queue_id}: #{inspect(e)}
Stacktrace: #{inspect(stacktrace)}")
          {:error, :unexpected_error} # Let Oban handle retry
      end

    Logger.info("Job for queue #{queue_id} finishing with result: #{inspect(result)}")
    result # Return :ok, {:error, ...}, or {:snooze, ...}
  end

  defp handle_successful_batch(queue_id, max_throughput, time_str, period) do
    delay = calculate_delay(time_str, period)

    if delay <= 10 do
      # For short intervals, check if still active and snooze if necessary
      check_active_and_snooze_or_complete(queue_id, delay)
    else
      # For longer intervals, schedule a new job like before
      schedule_next_job(queue_id, max_throughput, time_str, period)
      :ok # Return :ok because scheduling the next job was successful for this one.
    end
  end

  defp check_active_and_snooze_or_complete(queue_id, delay) do
    case queue_active?(queue_id) do
      {:ok, true} ->
        # Queue still has items, snooze to run again
        Logger.debug("Queue #{queue_id} still active, snoozing for #{delay} seconds.")
        {:snooze, delay}
      {:ok, false} ->
        # Queue appears empty *now*. Let the job finish.
        # JobCleaner or ActionBatcher will restart it if needed later.
        Logger.debug("Queue #{queue_id} now inactive/empty, completing job after snooze-eligible interval.")
        :ok
      {:error, reason} ->
         # Error checking status, better to let Oban retry the whole job.
         Logger.error("Error checking queue status after processing for #{queue_id}: #{inspect(reason)}")
         {:error, {:queue_check_failed, reason}}
    end
  end

  defp queue_active?(queue_id) do
    Logger.debug("Checking if queue #{queue_id} is active")

    query = from(a in ActionExecution,
                  where: a.queue_id == ^queue_id,
                  where: not a.processed,
                  order_by: [desc: a.inserted_at],
                  select: a.inserted_at,
                  limit: 1)

    case Repo.one(query) do
      nil ->
        Logger.debug("No active executions found for queue #{queue_id}")
        {:ok, false}
      _ ->
        Logger.debug("Active executions found for queue #{queue_id}")
        {:ok, true}
    end
  end


  defp get_next_action_batch(queue_id, max_throughput) do
    throughput = String.to_integer(max_throughput)
    now = DateTime.utc_now()

    query = from(a in ActionExecution,
                 where: a.queue_id == ^queue_id and not a.processed,
                 where: is_nil(a.on_hold_until) or a.on_hold_until <= ^now,
                 order_by: [asc: a.inserted_at],
                 limit: ^throughput)

    case Repo.all(query) do
      [] ->
        Logger.debug("No executions found for queue #{queue_id}")
        {:ok, []}
      executions ->
        Logger.debug("Found #{length(executions)} executions to process")
        {:ok, executions}
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
        DynamicSupervisor.start_child(Throttle.PortalQueueSupervisor, {Throttle.PortalQueue, portal_id})
      _ ->
        :ok
    end
  end

  @max_consecutive_failures 3 # Put actions on hold after this many consecutive failures
  @hold_duration_seconds 1800 # Hold for 30 minutes (1800 seconds)

  def process_with_token(executions, token) do
    Logger.info("Processing with token for portal: #{token.portal_id}")

    unique_executions = Enum.uniq_by(executions, & &1.callback_id)
    action_ids = Enum.map(unique_executions, & &1.id)

    if length(unique_executions) < length(executions) do
      Logger.warning("Filtered out #{length(executions) - length(unique_executions)} duplicate callback IDs")
    end

    case send_batch_complete_with_retry(unique_executions, token.access_token) do
      :ok ->
        # Success: Mark processed and clear error fields
        Logger.info("Batch complete sent successfully for actions: #{inspect(action_ids)}")
        mark_actions_processed_and_clear_errors(action_ids)
        :ok

      {:error, {:http_error, 403, _body}} ->
        # Handle 403 specifically: Increment failure count, potentially put on hold
        Logger.error("Batch failed with 403 Forbidden for actions: #{inspect(action_ids)}. Incrementing failure count.")
        handle_batch_failure(action_ids, "forbidden")
        {:error, :forbidden} # Return specific error

      {:error, {:rate_limited, retry_after}} ->
        # Rate limited: Don't change error state, will be retried by Oban or next run
        Logger.warning("Batch rate limited (429) for actions: #{inspect(action_ids)}. Will retry later.")
        {:error, {:rate_limited, retry_after}}

      error ->
        # Other errors: Increment failure count, potentially put on hold
        Logger.error("Error sending batch complete for actions: #{inspect(action_ids)}. Error: #{inspect(error)}. Incrementing failure count.")
        handle_batch_failure(action_ids, "other_error")
        error # Return original error
    end
  end

  defp send_batch_complete_with_retry(executions, access_token, retries \\ 3) do
    case send_batch_complete(executions, access_token) do
      :ok -> :ok
      {:error, {:rate_limited, retry_after}} when retries > 0 ->
        Logger.warning(fn ->
          "Rate limited by HubSpot API, retrying in #{retry_after} seconds (#{retries} retries left)"
        end)
        :timer.sleep(retry_after * 1000)
        send_batch_complete_with_retry(executions, access_token, retries - 1)
      {:error, reason} when retries > 0 ->
        Logger.warning(fn ->
          "Error occurred: #{inspect(reason)}, retrying (#{retries} retries left)"
        end)
        :timer.sleep(2000)
        send_batch_complete_with_retry(executions, access_token, retries - 1)
      {:error, reason} ->
        {:error, reason}
    end
  end


  defp extract_portal_id(execution) do
    execution.queue_id |> String.split(":") |> Enum.at(1) |> String.to_integer()
  end

  defp send_batch_complete(executions, access_token) do
    Logger.info(fn -> "Sending batch complete for #{length(executions)} executions" end)
    url = "https://api.hubapi.com/automation/v4/actions/callbacks/complete"

    body = Jason.encode!(%{
      inputs: Enum.map(executions, fn execution ->
        %{
          callbackId: execution.callback_id,
          outputFields: %{hs_execution_state: "SUCCESS"}
        }
      end)
    })

    headers = [
      {"Authorization", "Bearer #{access_token}"},
      {"Content-Type", "application/json"}
    ]

    case HTTPoison.post(url, body, headers) do
      {:ok, %{status_code: 204}} ->
        Logger.debug("Batch complete request successful")
        :ok

      {:ok, %{status_code: 403, body: response_body}} ->
        # Handle Cloudflare/other 403 block specifically
        ray_id = extract_cloudflare_ray_id(response_body)
        Logger.error("API request blocked (403 Forbidden). Ray ID: #{ray_id || "Not Found"}.")
        {:error, {:http_error, 403, response_body}} # Return error without crashing

      {:ok, %{status_code: 429, headers: response_headers}} ->
        retry_after = extract_retry_after(response_headers) || 60
        Logger.warning("Rate limited by HubSpot API (429), retry after #{retry_after} seconds")
        {:error, {:rate_limited, retry_after}}

      {:ok, response} ->
        # Attempt to parse other errors as JSON, but handle potential decode errors
        case Jason.decode(response.body) do
          {:ok, parsed_body} ->
            Logger.error("API error: Status #{response.status_code}, Body: #{inspect(parsed_body)}")
            {:error, {:api_error, response.status_code, parsed_body}}
          {:error, decode_error} ->
             Logger.error("API error: Status #{response.status_code}, Failed to decode JSON body: #{inspect(decode_error)}, Body: #{inspect(response.body)}")
             {:error, {:http_error, response.status_code, response.body}}
        end

      {:error, error} ->
        Logger.error("HTTP error: #{inspect(error.reason)}")
        {:error, {:http_error, error.reason}} # Note: a bit inconsistent, maybe {:http_client_error, reason}?
    end
  end

  # Add a helper function to extract Ray ID (simple regex approach)
  defp extract_cloudflare_ray_id(body) when is_binary(body) do
    case Regex.run(~r/Cloudflare Ray ID: <strong[^>]*>([a-f0-9]+)<\/strong>/i, body) do
      [_, ray_id] -> ray_id
      _ -> nil
    end
  end
  defp extract_cloudflare_ray_id(_), do: nil

  defp mark_actions_processed(action_ids) do
    {_count, _} = from(a in ActionExecution, where: a.id in ^action_ids)
    |> Repo.update_all(set: [processed: true])
  end

  # New function to mark processed AND clear error state
  defp mark_actions_processed_and_clear_errors(action_ids) do
    {_count, _} = from(a in ActionExecution, where: a.id in ^action_ids)
    |> Repo.update_all(set: [
      processed: true,
      last_failure_reason: nil,
      consecutive_failures: 0,
      on_hold_until: nil
    ])
  end

  # New function to handle batch failure updates
  defp handle_batch_failure(action_ids, reason) do
    now = DateTime.utc_now()
    # We need to update based on the current state in the DB, which requires a more complex update.
    # Easiest way is often to fetch, update, and save, but that's inefficient for batches.
    # Using update_all with a CASE statement or fragment is possible but complex.
    # Let's do a simpler update_all for now, acknowledging it might reset the hold period
    # if an action fails again while already on hold.

    # Increment consecutive_failures and set reason
    Repo.update_all(
      from(a in ActionExecution, where: a.id in ^action_ids),
      inc: [consecutive_failures: 1],
      set: [last_failure_reason: reason]
    )

    # Check which actions have exceeded the failure threshold and put them on hold
    hold_until = DateTime.add(now, @hold_duration_seconds, :second)
    Repo.update_all(
      from(a in ActionExecution, where: a.id in ^action_ids and a.consecutive_failures >= @max_consecutive_failures),
      set: [on_hold_until: hold_until]
    )
  end


  defp schedule_next_job(queue_id, max_throughput, time, period) do
      delay = calculate_delay(time, period)
      Logger.debug("ThrottleWorker: Scheduling next job for queue #{queue_id} with delay: #{delay} seconds")

      job_params = %{
        queue_id: queue_id,
        max_throughput: to_string(max_throughput),
        time: to_string(time),
        period: period
      }
      Oban.insert(new(job_params, schedule_in: delay))
    end

  defp calculate_delay(time, period) do
    time = String.to_integer(time)
    case period do
      "seconds" -> time
      "minutes" -> time * 60
      "hours" -> time * 3600
      "days" -> time * 86400
      _ ->
        Logger.warning("ThrottleWorker: Invalid period #{period}, defaulting to seconds")
        time
    end
  end

  defp extract_retry_after(headers) do
    headers
    |> Enum.find_value(fn
      {"Retry-After", value} -> String.to_integer(value)
      _ -> nil
    end)
  end
end
