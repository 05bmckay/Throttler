defmodule Throttle.Dispatcher do
  @moduledoc "Bounded task scheduler. All work and timing remain recoverable in Postgres."
  use GenServer
  require Logger
  alias Throttle.DispatchStore
  @poll_ms 250
  @task_timeout_ms 120_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def status, do: GenServer.call(__MODULE__, :status, 1_000)

  def handle_call(:status, _from, state),
    do: {:reply, %{enabled: state.enabled, active_tasks: map_size(state.tasks)}, state}

  def init(opts) do
    state = %{
      tasks: %{},
      timer: nil,
      concurrency: Keyword.get(opts, :concurrency, 16),
      enabled: Application.get_env(:throttle, :dispatch_enabled, false),
      delivery: Keyword.get(opts, :delivery, Throttle.Delivery)
    }

    {:ok, schedule(state)}
  end

  def handle_info(:poll, state) do
    state = %{state | timer: nil}
    state = if state.enabled, do: fill_capacity(state), else: state
    {:noreply, schedule(state)}
  end

  # Logger overload flushing can reply directly to the caller PID after its
  # synchronous call timed out. This alias-tagged reply is not a delivery
  # result. Do not log it and feed more work back into the overloaded logger.
  def handle_info({[:alias | ref], :dropped}, state) when is_reference(ref),
    do: {:noreply, state}

  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    finished = forget_task(state, ref)
    if state.enabled and Map.has_key?(state.tasks, ref), do: send(self(), :drain)
    {:noreply, finished}
  end

  def handle_info(:drain, %{enabled: true} = state), do: {:noreply, fill_capacity(state)}
  def handle_info(:drain, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if Map.has_key?(state.tasks, ref) do
      Logger.warning(
        "Delivery task exited; database lease will recover its work: #{if is_atom(reason), do: reason, else: :unexpected_exit}"
      )
    end

    finished = forget_task(state, ref)
    if state.enabled and Map.has_key?(state.tasks, ref), do: send(self(), :drain)
    {:noreply, finished}
  end

  def handle_info({:task_timeout, ref}, state) do
    if entry = state.tasks[ref],
      do: Task.Supervisor.terminate_child(Throttle.DeliverySupervisor, entry.pid)

    # Keep the slot until DOWN. Never overlap a task with its replacement.
    {:noreply, state}
  end

  defp fill_capacity(state) do
    free = state.concurrency - map_size(state.tasks)

    if free <= 0 do
      state
    else
      DispatchStore.ready_portals(free)
      |> Enum.reduce(state, fn portal, acc ->
        task =
          Task.Supervisor.async_nolink(Throttle.DeliverySupervisor, fn ->
            case DispatchStore.claim(portal) do
              {:ok, nil} -> :idle
              {:ok, batch} -> acc.delivery.run(batch)
              {:error, reason} -> {:error, reason}
            end
          end)

        timer = Process.send_after(self(), {:task_timeout, task.ref}, @task_timeout_ms)
        put_in(acc.tasks[task.ref], %{pid: task.pid, timer: timer})
      end)
    end
  rescue
    _e in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning("Dispatcher database unavailable; retrying on next poll")
      state
  end

  defp forget_task(state, ref) do
    case Map.pop(state.tasks, ref) do
      {nil, _} ->
        state

      {entry, tasks} ->
        Process.cancel_timer(entry.timer)
        %{state | tasks: tasks}
    end
  end

  defp schedule(state), do: %{state | timer: Process.send_after(self(), :poll, @poll_ms)}
end
