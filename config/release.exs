import Config


secret_key_base =
  System.get_env("SECRET_KEY_BASE") ||
    raise """
    environment variable SECRET_KEY_BASE is missing.
    You can generate one by calling: mix phx.gen.secret
    """

# Configure your database
config :throttle, Throttle.Repo,
  url: System.get_env("DATABASE_URL"),
  show_sensitive_data_on_connection_error: true,
  pool_size: 50,
  ssl: true,
  ssl_opts: [
     verify: :verify_none
  ]

# For development, we disable any cache and enable
# debugging and code reloading.
config :throttle, ThrottleWeb.Endpoint,
  http: [
      port: String.to_integer(System.get_env("PORT") || "4000"),
      transport_options: [socket_opts: [:inet6]]
  ],
  check_origin: false,
  secret_key_base: secret_key_base,
  url: [host: System.get_env("BASE_URL"), scheme: "https"],
  watchers: []

config :sentry,
  dsn: "https://17a4dbd176cadd61cab6e436bfad3e16@o4507926265790464.ingest.us.sentry.io/4507926269263872",
  environment_name: Mix.env(),
  enable_source_code_context: true,
  root_source_code_paths: [File.cwd!()]

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

# Configure Oban
config :throttle, Oban,
  repo: YourApp.Repo,
  plugins: [Oban.Plugins.Pruner],
  queues: [default: 10]

# HubSpot and encryption configuration
config :throttle,
  hubspot_client_id: System.get_env("HUBSPOT_CLIENT_ID"),
  hubspot_client_secret: System.get_env("HUBSPOT_CLIENT_SECRET"),
  hubspot_redirect_uri: "https://throttler-app.cartermckay.com/api/oauth/callback",
  encryption_key: System.get_env("ENCRYPTION_KEY")
