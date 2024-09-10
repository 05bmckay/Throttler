defmodule Throttle.ThrottleWorker do
  use Oban.Worker, queue: :default, max_attempts: 3
  require Logger
  alias Throttle.{Repo, OAuthManager}
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
                 where: a.queue_id == ^queue_id and not a.processed,
                 order_by: [desc: :inserted_at],
                 limit: 1,
                 select: a.inserted_at)

    case Repo.one(query) do
      nil ->
        Logger.debug("No active executions found for queue #{queue_id}")
        {:ok, false}

      timestamp ->
        # Convert NaiveDateTime to DateTime in UTC
        datetime = DateTime.from_naive!(timestamp, "Etc/UTC")
        is_active = DateTime.diff(DateTime.utc_now(), datetime) <= 4 * 3600
        Logger.debug("Queue #{queue_id} active status: #{is_active}, last execution at: #{NaiveDateTime.to_string(timestamp)}")
        {:ok, is_active}
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


  #TODO switch the HTTP Call first and then Mark processed
  defp process_executions(executions) do
      executions_by_portal = Enum.group_by(executions, &extract_portal_id/1)
      Logger.info(fn -> "Processing executions for portals: #{inspect(Map.keys(executions_by_portal))}" end)

      Repo.transaction(fn ->
        Enum.each(executions_by_portal, fn {portal_id, portal_executions} ->
          Logger.info(fn -> "Processing portal: #{portal_id}" end)
          case OAuthManager.get_token(portal_id) do
            {:ok, token} ->
              Logger.info(fn -> "Token retrieved for portal #{portal_id}" end)
              process_with_token(portal_executions, token)
            {:error, reason} ->
              Logger.error("Error getting token for portal #{portal_id}: #{inspect(reason)}", portal_id: portal_id)
              Repo.rollback(reason)
          end
        end)
      end)
    end

    defp process_with_token(executions, token) do
      Logger.info(fn -> "Processing with token for portal: #{token.portal_id}" end)
      case send_batch_complete_with_retry(executions, token.access_token) do
        :ok ->
          Logger.info(fn -> "Batch complete sent successfully" end)
          mark_actions_processed(Enum.map(executions, & &1.id))
        error ->
          Logger.error(fn -> "Error sending batch complete: #{inspect(error)}" end)
          Repo.rollback(error)
      end
    end

    defp send_batch_complete_with_retry(executions, access_token, retries \\ 3) do
        case send_batch_complete(executions, access_token) do
          :ok -> :ok
          {:error, :unauthorized} when retries > 0 ->
            Logger.warning(fn -> "Unauthorized error, retrying in 2 seconds (#{retries} retries left)" end)
            :timer.sleep(2000)  # Wait for 2 seconds before retrying
            send_batch_complete_with_retry(executions, access_token, retries - 1)
          error -> error
        end
      end

  defp extract_portal_id(execution) do
    execution.queue_id |> String.split(":") |> Enum.at(1) |> String.to_integer()
  end

  defp send_batch_complete(executions, access_token) do
      Logger.info(fn -> "Sending batch complete for #{length(executions)} executions" end)
      url = "https://api.hubapi.com/automation/v4/actions/callbacks/complete"
      headers = [
        {"Authorization", "Bearer #{access_token}"},
        {"Content-Type", "application/json"}
      ]
    body = Jason.encode!(%{
      inputs: Enum.map(executions, fn execution ->
        %{
          callbackId: execution.callback_id,
          outputFields: %{hs_execution_state: "SUCCESS"}
        }
      end)
    })

    case HTTPoison.post(url, body, headers) do
      {:ok, %{status_code: 204}} ->
        Logger.debug("Batch complete request successful")
        :ok
      {:ok, %{status_code: 401}} ->
        Logger.error("Unauthorized error when sending batch complete request")
        {:error, :unauthorized}
      {:ok, response} ->
        Logger.error("API error when sending batch complete request: Status #{response.status_code}, Body: #{inspect(response.body)}")
        {:error, {:api_error, response.status_code, response.body}}
      {:error, error} ->
        Logger.error("HTTP error when sending batch complete request: #{inspect(error.reason)}")
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
end
