import Config

database_url =
  System.get_env("TEST_DATABASE_URL") ||
    "ecto://#{System.get_env("USER") || "postgres"}@localhost/throttle_test#{System.get_env("MIX_TEST_PARTITION") || ""}"

config :throttle, Throttle.Repo,
  url: database_url,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :throttle, ThrottleWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: String.duplicate("test-secret-key-base-", 4),
  server: false

config :throttle, Oban,
  testing: :manual,
  plugins: false,
  queues: false

config :throttle,
  env: :test,
  hubspot_client_secret: "test-client-secret",
  hubspot_block_expiration_duration: "P4W",
  startup_recovery_queues: 0,
  encryption_key: Base.encode64(:binary.copy(<<1>>, 32))

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
