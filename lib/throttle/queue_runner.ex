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
  # A drained runner exits normally and should stay stopped until new work arrives.
  # The default `:permanent` restart policy turns that normal lifecycle into a
  # DynamicSupervisor restart storm when several queues drain together.
  use GenServer, restart: :transient
  require Logger

  alias Throttle.ActionQueries

  @idle_timeout_ms 10_000

  ## Client API

  @doc """
  Ensures a QueueRunner is running for the given queue_id.

  Idempotent — if a runner already exists, returns its pid.
  Handles the race condition where two callers try to start simultaneously.
  """
  def ensure_started(queue_id) do
    with {:ok, config} <- ActionQueries.latest_queue_config(queue_id) do
      case Registry.lookup(Throttle.QueueRunnerRegistry, queue_id) do
        [{pid, _}] ->
          :ok = GenServer.call(pid, {:update_config, config})
          {:ok, pid}

        [] ->
          case DynamicSupervisor.start_child(
                 Throttle.QueueRunnerSupervisor,
                 {__MODULE__, {queue_id, config}}
               ) do
            {:ok, pid} ->
              {:ok, pid}

            {:error, {:already_started, pid}} ->
              :ok = GenServer.call(pid, {:update_config, config})
              {:ok, pid}

            error ->
              error
          end
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
      config_id: config.config_id,
      max_throughput: config.max_throughput,
      time: config.time,
      period: config.period,
      delay_ms: calculate_delay_ms(config.time, config.period),
      timer_ref: nil,
      in_flight: %{},
      portal_pid: nil,
      portal_monitor_ref: nil,
      idle_since: nil
    }

    Logger.info("QueueRunner started for #{queue_id} (every #{state.delay_ms}ms)")

    send(self(), :tick)

    {:ok, state}
  end

  def handle_call({:update_config, config}, _from, state) do
    cond do
      config.config_id <= state.config_id ->
        {:reply, :ok, state}

      same_rate?(state, config) ->
        {:reply, :ok, %{state | config_id: config.config_id}}

      true ->
        updated = apply_config(state, config)

        if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

        Logger.info(
          "QueueRunner #{state.queue_id} rate updated from #{state.max_throughput}/#{state.time} #{state.period} to #{updated.max_throughput}/#{updated.time} #{updated.period}"
        )

        timer_ref = Process.send_after(self(), :tick, updated.delay_ms)
        {:reply, :ok, %{updated | timer_ref: timer_ref, idle_since: nil}}
    end
  end

  def handle_info(:tick, %{in_flight: in_flight} = state) when map_size(in_flight) > 0 do
    # A queue may have only one delivery batch outstanding at a time. The old
    # implementation kept claiming at the configured rate while PortalQueue
    # was still delivering earlier batches. Once the 180-second DB leases
    # expired, those same rows were claimed and enqueued again indefinitely.
    timer_ref = Process.send_after(self(), :tick, state.delay_ms)
    {:noreply, %{state | timer_ref: timer_ref, idle_since: nil}}
  end

  def handle_info(:tick, state) do
    now = System.monotonic_time(:millisecond)

    try do
      case ActionQueries.get_next_action_batch(state.queue_id, state.max_throughput, []) do
        {:ok, []} ->
          idle_since = state.idle_since || now

          if now - idle_since >= @idle_timeout_ms do
            Logger.info("QueueRunner #{state.queue_id} idle for #{@idle_timeout_ms}ms, stopping.")
            {:stop, :normal, state}
          else
            timer_ref = Process.send_after(self(), :tick, state.delay_ms)

            {:noreply, %{state | timer_ref: timer_ref, idle_since: idle_since}}
          end

        {:ok, executions} ->
          new_entries = Map.new(executions, fn e -> {e.id, now} end)
          timer_ref = Process.send_after(self(), :tick, state.delay_ms)

          case process_executions(executions) do
            {:ok, portal_pid} ->
              monitored_state = monitor_portal(state, portal_pid)

              {:noreply,
               %{
                 monitored_state
                 | timer_ref: timer_ref,
                   in_flight: new_entries,
                   idle_since: nil
               }}

            {:error, reason} ->
              Logger.error(
                "QueueRunner #{state.queue_id} could not enqueue claimed actions: #{inspect(reason)}"
              )

              {:noreply, %{state | timer_ref: timer_ref, idle_since: nil}}
          end

        {:error, reason} ->
          Logger.error(
            "QueueRunner #{state.queue_id} could not claim actions: #{inspect(reason)}"
          )

          timer_ref = Process.send_after(self(), :tick, state.delay_ms)
          {:noreply, %{state | timer_ref: timer_ref}}
      end
    rescue
      e ->
        Logger.error("QueueRunner #{state.queue_id} tick error: #{Exception.message(e)}")

        timer_ref = Process.send_after(self(), :tick, state.delay_ms)
        {:noreply, %{state | timer_ref: timer_ref}}
    end
  end

  def handle_info({:portal_delivery_complete, action_ids}, state) when is_list(action_ids) do
    completed = Map.take(state.in_flight, action_ids)
    remaining = Map.drop(state.in_flight, action_ids)

    if map_size(completed) > 0 and map_size(remaining) == 0 do
      if state.timer_ref do
        Process.cancel_timer(state.timer_ref)
      end

      started_at = completed |> Map.values() |> Enum.min()
      elapsed_ms = System.monotonic_time(:millisecond) - started_at
      next_tick_ms = max(state.delay_ms - elapsed_ms, 0)
      timer_ref = Process.send_after(self(), :tick, next_tick_ms)

      {:noreply, %{state | in_flight: remaining, timer_ref: timer_ref}}
    else
      {:noreply, %{state | in_flight: remaining}}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{portal_monitor_ref: ref} = state) do
    Logger.error(
      "PortalQueue #{inspect(pid)} for #{state.queue_id} exited while a batch was in flight: #{inspect(reason)}"
    )

    # The database lease remains authoritative. Clearing only the local map
    # allows the row to become claimable after that lease expires.
    {:noreply,
     %{state | in_flight: %{}, portal_pid: nil, portal_monitor_ref: nil, idle_since: nil}}
  end

  def terminate(reason, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    Logger.info("QueueRunner #{state.queue_id} terminated: #{inspect(reason)}")
    :ok
  end

  ## Private

  defp process_executions(executions) do
    executions_by_portal = Enum.group_by(executions, &extract_portal_id/1)

    Enum.reduce_while(executions_by_portal, {:error, :no_portal}, fn
      {portal_id, portal_executions}, _acc ->
        case ensure_portal_queue(portal_id) do
          {:ok, pid} ->
            Throttle.PortalQueue.enqueue_executions(portal_id, portal_executions, self())
            {:cont, {:ok, pid}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
    end)
  end

  defp ensure_portal_queue(portal_id) do
    case Registry.lookup(Throttle.PortalRegistry, portal_id) do
      [] ->
        case DynamicSupervisor.start_child(
               Throttle.PortalQueueSupervisor,
               {Throttle.PortalQueue, portal_id}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end

      [{pid, _}] ->
        {:ok, pid}
    end
  end

  defp extract_portal_id(execution) do
    case execution.queue_id |> String.split(":") |> Enum.at(1) do
      nil ->
        0

      val ->
        case Integer.parse(val) do
          {int, _} -> int
          :error -> 0
        end
    end
  end

  defp monitor_portal(%{portal_pid: pid} = state, pid), do: state

  defp monitor_portal(state, pid) do
    if state.portal_monitor_ref do
      Process.demonitor(state.portal_monitor_ref, [:flush])
    end

    %{state | portal_pid: pid, portal_monitor_ref: Process.monitor(pid)}
  end

  defp apply_config(state, config) do
    %{
      state
      | config_id: config.config_id,
        max_throughput: config.max_throughput,
        time: config.time,
        period: config.period,
        delay_ms: calculate_delay_ms(config.time, config.period)
    }
  end

  defp same_rate?(state, config) do
    state.max_throughput == config.max_throughput and state.time == config.time and
      state.period == config.period
  end

  defp calculate_delay_ms(time, period) do
    time_int =
      case Integer.parse(to_string(time)) do
        {int, _} -> int
        :error -> 1
      end

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
