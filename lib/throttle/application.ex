defmodule Throttle.Application do
  @moduledoc """
  The main application module for Throttle.
  This module is responsible for starting and supervising all the necessary processes.
  """
  use Application

  def start(_type, _args) do
    Throttle.BlockExpiration.configured_seconds!()
    :ok = Throttle.LogRedactor.install()

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
      {Finch,
       name: Throttle.Finch,
       pools: %{
         "https://api.hubapi.com" => [size: 25, count: 2]
       }},
      Throttle.DispatchSupervisor
    ]

    # A paused release must boot against the old schema during offline cutover.
    # Maintenance queries use the new columns, so pause them with dispatch.
    children =
      children ++
        if Application.get_env(:throttle, :dispatch_enabled, false),
          do: [{Oban, Application.get_env(:throttle, Oban)}],
          else: []

    opts = [strategy: :one_for_one, name: Throttle.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def config_change(changed, _new, removed) do
    ThrottleWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
