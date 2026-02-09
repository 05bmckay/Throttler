import Config

# Configure your database
config :throttle, Throttle.Repo,
  url: System.get_env("DEV_DATABASE_URL"),
  show_sensitive_data_on_connection_error: true,
  pool_size: 5,
  ssl: true,
  ssl_opts: [
    # TODO: Use verify: :verify_peer with cacerts: :public_key.cacerts_get() on OTP 25+
    verify: :verify_none
  ]

# For development, we disable any cache and enable
# debugging and code reloading.
config :throttle, ThrottleWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base:
    System.get_env(
      "SECRET_KEY_BASE",
      "dev-only-secret-key-base-must-be-at-least-64-bytes-long-for-phoenix-to-accept-it!!"
    ),
  url: [host: "throttler.cartermckay.com", port: 443, scheme: "https"],
  watchers: []

config :logger,
  level: :debug

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

# HubSpot and encryption configuration
config :throttle,
  hubspot_client_id: System.get_env("HUBSPOT_CLIENT_ID"),
  hubspot_client_secret: System.get_env("HUBSPOT_CLIENT_SECRET"),
  hubspot_redirect_uri: "https://throttler.cartermckay.com/api/oauth/callback",
  encryption_key: System.get_env("ENCRYPTION_KEY")
