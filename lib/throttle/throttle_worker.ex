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

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(60)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args_map}) do
    %{
      queue_id: queue_id,
      max_throughput: max_throughput,
      time: time,
      period: period
    } = normalize_args(args_map)

    config = %{max_throughput: max_throughput, time: time, period: period}

    case Throttle.QueueRunner.ensure_started(queue_id, config) do
      {:ok, _pid} ->
        Logger.info("QueueRunner started for queue #{queue_id}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to start QueueRunner for queue #{queue_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

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
end
