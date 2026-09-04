import Config

# Compile-time only. All runtime secrets (DATABASE_URL, SECRET_KEY_BASE, etc.)
# live in config/runtime.exs — do NOT add System.get_env() calls here.

config :throttle, ThrottleWeb.Endpoint, server: true

config :throttle, secure_session_cookie: true

config :logger,
  level: :info,
  handle_otp_reports: true,
  handle_sasl_reports: false

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]
