import Config

# Compile-time only. All runtime secrets (DATABASE_URL, SECRET_KEY_BASE, etc.)
# live in config/runtime.exs — do NOT add System.get_env() calls here.

config :throttle, ThrottleWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  server: true

config :logger,
  level: :info,
  handle_otp_reports: true,
  handle_sasl_reports: true

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]
