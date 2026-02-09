import Config

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL environment variable is not set"

  config :throttle, Throttle.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "90"),
    ssl: true,
    ssl_opts: [verify: :verify_none]

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE environment variable is not set"

  port = String.to_integer(System.get_env("PORT") || "4000")
  host = System.get_env("BASE_URL") || "localhost"

  config :throttle, ThrottleWeb.Endpoint,
    http: [port: port, transport_options: [socket_opts: [:inet6]]],
    url: [host: host, port: 443, scheme: "https"],
    secret_key_base: secret_key_base,
    server: true

  config :throttle,
    hubspot_client_id: System.get_env("HUBSPOT_CLIENT_ID"),
    hubspot_client_secret: System.get_env("HUBSPOT_CLIENT_SECRET"),
    hubspot_redirect_uri: System.get_env("HUBSPOT_REDIRECT_URI"),
    encryption_key:
      System.get_env("ENCRYPTION_KEY") ||
        raise("ENCRYPTION_KEY environment variable is not set")
end
