defmodule Throttle.Application do
  @moduledoc """
  The main application module for Throttle.
  This module is responsible for starting and supervising all the necessary processes.
  """
  use Application

  def start(_type, _args) do
    # Attach Oban's default telemetry logger for observability
    Oban.Telemetry.attach_default_logger(:info)

    children = [
      # Start the Ecto repository
      Throttle.Repo,
      # Start the Telemetry supervisor
      ThrottleWeb.Telemetry,
      # Start the PubSub system
      {Phoenix.PubSub, name: Throttle.PubSub},
      # Start the Endpoint (http/https)
      ThrottleWeb.Endpoint,
      {Task.Supervisor, name: Throttle.FlushTaskSupervisor},
      Throttle.ActionBatcher,
      Throttle.ConfigCache,
      Throttle.OAuthRefreshLock,
      {Finch,
       name: Throttle.Finch,
       pools: %{
         "https://api.hubapi.com" => [size: 25, count: 2]
       }},
      {Oban, Application.get_env(:throttle, Oban)},
      {Registry, keys: :unique, name: Throttle.QueueRunnerRegistry},
      {DynamicSupervisor,
       strategy: :one_for_one, name: Throttle.QueueRunnerSupervisor, max_children: 1000},
      {Registry, keys: :unique, name: Throttle.PortalRegistry},
      {DynamicSupervisor,
       strategy: :one_for_one, name: Throttle.PortalQueueSupervisor, max_children: 500}
    ]

    opts = [strategy: :one_for_one, name: Throttle.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def config_change(changed, _new, removed) do
    ThrottleWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
