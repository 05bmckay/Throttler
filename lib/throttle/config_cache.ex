defmodule Throttle.ConfigCache do
  use GenServer
  require Logger

  alias Throttle.Repo
  alias Throttle.Schemas.ThrottleConfig

  @ttl_ms :timer.minutes(5)

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def get_config(portal_id, action_id) do
    GenServer.call(__MODULE__, {:get, {portal_id, action_id}}, 5_000)
  end

  def bust_cache(portal_id, action_id) do
    GenServer.cast(__MODULE__, {:invalidate, {portal_id, action_id}})
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:get, key}, _from, cache) do
    now = System.monotonic_time(:millisecond)

    case Map.get(cache, key) do
      {%ThrottleConfig{} = config, cached_at} when now - cached_at < @ttl_ms ->
        {:reply, {:ok, config}, cache}

      _miss_or_expired ->
        {portal_id, action_id} = key

        case Repo.get_by(ThrottleConfig, portal_id: portal_id, action_id: action_id) do
          nil ->
            Logger.warning("No config found in DB for key: #{inspect(key)}")
            {:reply, {:error, :not_found}, Map.delete(cache, key)}

          %ThrottleConfig{} = config ->
            {:reply, {:ok, config}, Map.put(cache, key, {config, now})}
        end
    end
  end

  @impl true
  def handle_cast({:invalidate, key}, cache) do
    {:noreply, Map.delete(cache, key)}
  end
end
