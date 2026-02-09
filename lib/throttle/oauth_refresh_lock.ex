defmodule Throttle.OAuthRefreshLock do
  @moduledoc """
  Per-portal mutex that serializes OAuth token refreshes.

  When multiple PortalQueue workers for the same portal call `get_token/1`
  simultaneously and the token is expired, they would all trigger parallel
  `refresh_token/1` calls — racing to refresh the same token. This GenServer
  ensures only one refresh happens at a time per portal; other callers wait
  for the result.
  """

  use GenServer
  require Logger

  @refresh_timeout_ms 30_000
  @call_timeout_ms 35_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Executes `refresh_fn` for the given `portal_id`, ensuring only one refresh
  runs at a time per portal. If a refresh is already in progress, the caller
  blocks until it completes and receives the same result.

  `refresh_fn` must be a zero-arity function returning `{:ok, token}` or
  `{:error, reason}`.

  Returns `{:ok, token}` or `{:error, reason}`.
  """
  def refresh_if_needed(portal_id, refresh_fn) do
    GenServer.call(__MODULE__, {:refresh, portal_id, refresh_fn}, @call_timeout_ms)
  end

  @impl true
  def init(_opts) do
    {:ok, %{portals: %{}}}
  end

  @impl true
  def handle_call({:refresh, portal_id, refresh_fn}, from, state) do
    case Map.get(state.portals, portal_id) do
      nil ->
        task_ref = start_refresh_task(portal_id, refresh_fn)

        new_portals =
          Map.put(state.portals, portal_id, %{
            task_ref: task_ref,
            waiters: [from]
          })

        {:noreply, %{state | portals: new_portals}}

      %{waiters: waiters} = entry ->
        Logger.info("OAuth refresh already in progress for portal #{portal_id}, queuing caller")

        new_portals =
          Map.put(state.portals, portal_id, %{entry | waiters: [from | waiters]})

        {:noreply, %{state | portals: new_portals}}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case find_portal_by_ref(state.portals, ref) do
      {portal_id, %{waiters: waiters}} ->
        Logger.info(
          "OAuth refresh completed for portal #{portal_id}, notifying #{length(waiters)} waiter(s)"
        )

        for waiter <- waiters do
          GenServer.reply(waiter, result)
        end

        {:noreply, %{state | portals: Map.delete(state.portals, portal_id)}}

      nil ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case find_portal_by_ref(state.portals, ref) do
      {portal_id, %{waiters: waiters}} ->
        Logger.error("OAuth refresh task crashed for portal #{portal_id}: #{inspect(reason)}")

        for waiter <- waiters do
          GenServer.reply(waiter, {:error, :refresh_crashed})
        end

        {:noreply, %{state | portals: Map.delete(state.portals, portal_id)}}

      nil ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:refresh_timeout, portal_id, ref}, state) do
    case Map.get(state.portals, portal_id) do
      %{task_ref: ^ref, waiters: waiters} ->
        Logger.error(
          "OAuth refresh timed out for portal #{portal_id} after #{@refresh_timeout_ms}ms"
        )

        for waiter <- waiters do
          GenServer.reply(waiter, {:error, :refresh_timeout})
        end

        Process.demonitor(ref, [:flush])

        {:noreply, %{state | portals: Map.delete(state.portals, portal_id)}}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp start_refresh_task(portal_id, refresh_fn) do
    %Task{ref: ref} =
      Task.Supervisor.async_nolink(Throttle.FlushTaskSupervisor, fn -> refresh_fn.() end)

    Process.send_after(self(), {:refresh_timeout, portal_id, ref}, @refresh_timeout_ms)

    ref
  end

  defp find_portal_by_ref(portals, ref) do
    Enum.find_value(portals, fn
      {portal_id, %{task_ref: ^ref} = entry} -> {portal_id, entry}
      _ -> nil
    end)
  end
end
