import Config

# General application configuration
config :throttle,
  ecto_repos: [Throttle.Repo],
  # HubSpot otherwise releases blocked actions after one week, even when the
  # throttler has not completed them. Four weeks is an explicit, configurable
  # safety window; queue-size validation is still required for extreme rates.
  hubspot_block_expiration_duration: "P4W",
  dispatch_enabled: false

# Configures the endpoint
config :throttle, ThrottleWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [view: ThrottleWeb.ErrorView, accepts: ~w(json), layout: false],
  pubsub_server: Throttle.PubSub

# Configures Elixir's Logger
config :logger,
  level: :debug

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

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

import_config "#{config_env()}.exs"
