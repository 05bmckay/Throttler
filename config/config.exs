import Config

# General application configuration
config :throttle,
  ecto_repos: [Throttle.Repo]

# Configures the endpoint
config :throttle, ThrottleWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [view: ThrottleWeb.ErrorView, accepts: ~w(json), layout: false],
  pubsub_server: Throttle.PubSub,
  live_view: [signing_salt: "CHANGE_ME"]

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
  plugins: [Oban.Plugins.Pruner],
  queues: [default: 10]

# Remove the following lines if present
# config :throttle, :redis_url, System.get_env("REDIS_URL")
