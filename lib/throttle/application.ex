defmodule Throttle.Application do
  @moduledoc """
  The main application module for Throttle.
  This module is responsible for starting and supervising all the necessary processes.
  """
  use Application

  def start(_type, _args) do
    children = [
      # Start the Ecto repository
      Throttle.Repo,
      # Start the Telemetry supervisor
      ThrottleWeb.Telemetry,
      # Start the PubSub system
      {Phoenix.PubSub, name: Throttle.PubSub},
      # Start the Endpoint (http/https)
      ThrottleWeb.Endpoint,
      # Start the ActionBatcher
      Throttle.ActionBatcher,
      # Start the ConfigCache
      Throttle.ConfigCache,
      # Start the JobBatcher
      {Throttle.JobBatcher, []},
      # Start Oban
      {Oban, Application.get_env(:throttle, Oban)},
      # Start Registry for portal queues
      {Registry, keys: :unique, name: Throttle.PortalRegistry},
      # Start DynamicSupervisor for portal queues
      {DynamicSupervisor, strategy: :one_for_one, name: Throttle.PortalQueueSupervisor}
    ]

    opts = [strategy: :one_for_one, name: Throttle.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def config_change(changed, _new, removed) do
    ThrottleWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
