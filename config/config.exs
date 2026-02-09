import Config

# General application configuration
config :throttle,
  ecto_repos: [Throttle.Repo]

# Configures the endpoint
config :throttle, ThrottleWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [view: ThrottleWeb.ErrorView, accepts: ~w(json), layout: false],
  pubsub_server: Throttle.PubSub,
  live_view: [signing_salt: "t8Kx9RzP"]

# Configures Elixir's Logger
config :logger,
  level: :debug

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"

config :throttle, Oban,
  repo: Throttle.Repo,
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron,
     crontab: [
       # Run the JobCleaner every 5 minutes
       {"*/5 * * * *", Throttle.Workers.JobCleaner},
       # Run the DataRetentionWorker daily at 3:00 AM UTC
       {"0 3 * * *", Throttle.Workers.DataRetentionWorker}
     ]}
  ],
  queues: [default: 10, rate_limited: 1, maintenance: 1]
