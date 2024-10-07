defmodule Throttle.ThrottleWorker do
  use Oban.Worker, queue: :default, max_attempts: 3
  require Logger
  alias Throttle.Repo
  alias Throttle.Schemas.ActionExecution
  import Ecto.Query

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"queue_id" => queue_id, "max_throughput" => max_throughput, "time" => time, "period" => period}} = _job) do
     result =
       try do
         case queue_active?(queue_id) do
           {:ok, true} ->
             case get_next_action_batch(queue_id, max_throughput) do
               {:ok, executions} ->
                 case process_executions(executions) do
                   :ok ->
                     schedule_next_job(queue_id, max_throughput, time, period)
                     :ok
                   {:ok, :ok} ->
                     schedule_next_job(queue_id, max_throughput, time, period)
                     :ok
                   {:error, reason} ->
                     Logger.error("Error processing executions for queue #{queue_id}: #{inspect(reason)}")
                     {:error, reason}
                 end
               {:error, reason} ->
                 Logger.error("Error fetching batch for queue #{queue_id}: #{inspect(reason)}")
                 {:error, reason}
             end
           {:ok, false} ->
             Logger.info("Queue #{queue_id} is inactive or empty, skipping processing")
             {:error, :queue_inactive}
           {:error, reason} ->
             Logger.error("Error checking active status for queue #{queue_id}: #{inspect(reason)}")
             {:error, reason}
         end
       rescue
         e ->
           Logger.error("Unexpected error processing queue #{queue_id}: #{inspect(e)}")
           {:error, :unexpected_error}
       end
     Logger.info("Finished processing queue: #{queue_id}, result: #{inspect(result)}")
     result
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

    query = from(a in ActionExecution,
                 where: a.queue_id == ^queue_id and not a.processed,
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

  def process_with_token(executions, token) do
    Logger.info("Processing with token for portal: #{token.portal_id}")
    case send_batch_complete_with_retry(executions, token.access_token) do
      :ok ->
        Logger.info("Batch complete sent successfully")
        mark_actions_processed(Enum.map(executions, & &1.id))
        :ok
      error ->
        Logger.error("Error sending batch complete: #{inspect(error)}")
        error
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

     # Prepare the request as before
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
       {:ok, %{status_code: 429, headers: response_headers}} ->
         retry_after = extract_retry_after(response_headers) || 60
         Logger.error("Rate limited by HubSpot API, retry after #{retry_after} seconds")
         {:error, {:rate_limited, retry_after}}
       {:ok, response} ->
         Logger.error("API error: Status #{response.status_code}, Body: #{inspect(response.body)}")
         {:error, {:api_error, response.status_code, response.body}}
       {:error, error} ->
         Logger.error("HTTP error: #{inspect(error.reason)}")
         {:error, {:http_error, error.reason}}
     end
   end

  defp mark_actions_processed(action_ids) do
    {_count, _} = from(a in ActionExecution, where: a.id in ^action_ids)
    |> Repo.update_all(set: [processed: true])
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
