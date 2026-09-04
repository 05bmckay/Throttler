import Config

# Local development defaults to a local database. Remote development databases
# must present a trusted certificate; never disable peer verification.
database_url =
  System.get_env("DEV_DATABASE_URL") || "ecto://#{System.get_env("USER")}@localhost/throttle_dev"

database_host = URI.parse(database_url).host

config :throttle, Throttle.Repo,
  url: database_url,
  pool_size: 5,
  ssl:
    if(database_host in ["localhost", "127.0.0.1"],
      do: false,
      else: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: String.to_charlist(database_host),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    )

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
