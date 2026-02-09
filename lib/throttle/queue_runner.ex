defmodule Throttle.QueueRunner do
  @moduledoc """
  Per-queue GenServer that drains action_executions at the configured rate.

  Uses `Process.send_after/3` for precise tick timing instead of Oban snooze/reschedule,
  eliminating DB writes for scheduling. Each tick fetches a batch of unprocessed actions
  and dispatches them to the per-portal PortalQueue for HTTP delivery.

  Lifecycle:
    - Started by ActionBatcher after inserting actions, or by ThrottleWorker (via JobCleaner recovery)
    - Ticks at the configured rate (e.g., every 1000ms for "1 second" period)
    - Stops itself when the queue is drained (no unprocessed actions)
    - Restarted by ActionBatcher when new actions arrive for the queue
  """
  use GenServer
  require Logger

  alias Throttle.ActionQueries

  ## Client API

  @doc """
  Ensures a QueueRunner is running for the given queue_id.

  Idempotent — if a runner already exists, returns its pid.
  Handles the race condition where two callers try to start simultaneously.
  """
  def ensure_started(queue_id, config) do
    case Registry.lookup(Throttle.QueueRunnerRegistry, queue_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               Throttle.QueueRunnerSupervisor,
               {__MODULE__, {queue_id, config}}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end
    end
  end

  def start_link({queue_id, config}) do
    GenServer.start_link(__MODULE__, {queue_id, config}, name: via_tuple(queue_id))
  end

  ## Server Callbacks

  def init({queue_id, config}) do
    state = %{
      queue_id: queue_id,
      max_throughput: config.max_throughput,
      time: config.time,
      period: config.period,
      delay_ms: calculate_delay_ms(config.time, config.period),
      timer_ref: nil
    }

    Logger.info("QueueRunner started for #{queue_id} (every #{state.delay_ms}ms)")

    send(self(), :tick)

    {:ok, state}
  end

  def handle_info(:tick, state) do
    try do
      case ActionQueries.get_next_action_batch(state.queue_id, state.max_throughput) do
        {:ok, []} ->
          Logger.info("QueueRunner #{state.queue_id} drained, stopping.")
          {:stop, :normal, state}

        {:ok, executions} ->
          process_executions(executions)
          timer_ref = Process.send_after(self(), :tick, state.delay_ms)
          {:noreply, %{state | timer_ref: timer_ref}}
      end
    rescue
      e ->
        Logger.error("QueueRunner #{state.queue_id} tick error: #{Exception.message(e)}")

        # Schedule next tick anyway — don't let transient errors kill the loop
        timer_ref = Process.send_after(self(), :tick, state.delay_ms)
        {:noreply, %{state | timer_ref: timer_ref}}
    end
  end

  def terminate(reason, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    Logger.info("QueueRunner #{state.queue_id} terminated: #{inspect(reason)}")
    :ok
  end

  ## Private

  defp process_executions(executions) do
    executions_by_portal = Enum.group_by(executions, &extract_portal_id/1)

    Enum.each(executions_by_portal, fn {portal_id, portal_executions} ->
      ensure_portal_queue(portal_id)
      Throttle.PortalQueue.enqueue_executions(portal_id, portal_executions)
    end)
  end

  defp ensure_portal_queue(portal_id) do
    case Registry.lookup(Throttle.PortalRegistry, portal_id) do
      [] ->
        DynamicSupervisor.start_child(
          Throttle.PortalQueueSupervisor,
          {Throttle.PortalQueue, portal_id}
        )

      _ ->
        :ok
    end
  end

  defp extract_portal_id(execution) do
    execution.queue_id |> String.split(":") |> Enum.at(1) |> String.to_integer()
  end

  defp calculate_delay_ms(time, period) do
    time_int = String.to_integer(time)

    case period do
      "seconds" ->
        time_int * 1_000

      "minutes" ->
        time_int * 60_000

      "hours" ->
        time_int * 3_600_000

      "days" ->
        time_int * 86_400_000

      _ ->
        Logger.warning("QueueRunner: Invalid period #{period}, defaulting to seconds")
        time_int * 1_000
    end
  end

  defp via_tuple(queue_id) do
    {:via, Registry, {Throttle.QueueRunnerRegistry, queue_id}}
  end
end
