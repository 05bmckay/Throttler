import Config

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  config :throttle, Throttle.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "80")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  config :throttle, ThrottleWeb.Endpoint,
    http: [
      port: String.to_integer(System.get_env("PORT") || "4000"),
      transport_options: [socket_opts: [:inet6]]
    ],
    secret_key_base: secret_key_base

  # Configure Oban
  config :throttle, Oban,
    repo: Throttle.Repo,
    plugins: [Oban.Plugins.Pruner],
    queues: [default: 10]

  # HubSpot and encryption configuration
  config :throttle,
    hubspot_client_id: System.get_env("HUBSPOT_CLIENT_ID"),
    hubspot_client_secret: System.get_env("HUBSPOT_CLIENT_SECRET"),
    encryption_key: System.get_env("ENCRYPTION_KEY")
end
