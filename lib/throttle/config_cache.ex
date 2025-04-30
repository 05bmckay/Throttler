defmodule Throttle.ConfigCache do
  @moduledoc """
  A simple GenServer-based cache for ThrottleConfig records.

  It stores configurations keyed by `{portal_id, action_id}`.
  Currently, it caches indefinitely without TTL or invalidation.
  """
  use GenServer
  require Logger

  alias Throttle.Configurations
  alias Throttle.Schemas.ThrottleConfig

  # Client API

  @doc """
  Starts the ConfigCache GenServer.
  """
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Fetches a ThrottleConfig from the cache or the database.

  Returns `{:ok, config}` or `{:error, :not_found}`.
  """
  def get_config(portal_id, action_id) do
    key = {portal_id, action_id}
    # Use call for synchronous fetch & update
    GenServer.call(__MODULE__, {:get, key})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    Logger.info("Starting ConfigCache")
    # State is a map: {portal_id, action_id} -> config
    {:ok, %{}}
  end

  @impl true
  def handle_call({:get, key}, _from, cache) do
    case Map.get(cache, key) do
      nil ->
        # Not in cache, fetch from DB
        Logger.debug("ConfigCache miss for key: #{inspect(key)}")
        {portal_id, action_id} = key
        case Configurations.get_throttle_config(portal_id, action_id) do
          nil ->
             # Not found in DB either
            {:reply, {:error, :not_found}, cache}
          %ThrottleConfig{} = config ->
            # Found in DB, store in cache and reply
            new_cache = Map.put(cache, key, config)
            {:reply, {:ok, config}, new_cache}
        end
      %ThrottleConfig{} = config ->
        # Found in cache
        Logger.debug("ConfigCache hit for key: #{inspect(key)}")
        {:reply, {:ok, config}, cache}
    end
  end

  # Optional: Add handle_cast/handle_info for cache invalidation later if needed
end
