import Config

if config_env() == :prod do
  required = fn name ->
    case System.get_env(name) do
      value when is_binary(value) and byte_size(value) > 0 -> value
      _ -> raise "#{name} environment variable is not set"
    end
  end

  encryption_key = required.("ENCRYPTION_KEY")

  case Base.decode64(encryption_key) do
    {:ok, key} when byte_size(key) == 32 -> :ok
    _ -> raise "ENCRYPTION_KEY must be base64 encoding of exactly 32 bytes"
  end

  requested_pool_size =
    case Integer.parse(System.get_env("POOL_SIZE") || "20") do
      {value, ""} when value > 0 -> value
      _ -> raise "POOL_SIZE must be a positive integer"
    end

  pool_size = min(requested_pool_size, 20)

  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL environment variable is not set"

  db_host = URI.parse(database_url).host || raise "DATABASE_URL must include a hostname"
  tls_name = System.get_env("DATABASE_TLS_SERVER_NAME") || db_host

  trust =
    case System.get_env("DATABASE_CA_CERT_PATH") do
      nil -> [cacerts: :public_key.cacerts_get()]
      path -> [cacertfile: String.to_charlist(path)]
    end

  config :throttle, Throttle.Repo,
    url: database_url,
    pool_size: pool_size,
    ssl:
      trust ++
        [
          verify: :verify_peer,
          server_name_indication: String.to_charlist(tls_name),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]

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
    hubspot_client_id: required.("HUBSPOT_CLIENT_ID"),
    hubspot_client_secret: required.("HUBSPOT_CLIENT_SECRET"),
    hubspot_redirect_uri: System.get_env("HUBSPOT_REDIRECT_URI"),
    admission_enabled: System.get_env("THROTTLE_ADMISSION_ENABLED") == "true",
    dispatch_enabled: System.get_env("THROTTLE_DISPATCH_ENABLED") == "true",
    config_api_key: System.get_env("THROTTLE_CONFIG_API_KEY"),
    hubspot_block_expiration_duration:
      System.get_env("HUBSPOT_BLOCK_EXPIRATION_DURATION") || "P4W",
    encryption_key: encryption_key
end
