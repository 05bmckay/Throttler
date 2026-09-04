defmodule ThrottleWeb.Plugs.ConfigAuth do
  @moduledoc "The optional operations configuration API is closed unless explicitly configured."
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, _opts) do
    expected = Application.get_env(:throttle, :config_api_key)

    authorized =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> provided] when is_binary(expected) and byte_size(expected) >= 32 ->
          Plug.Crypto.secure_compare(provided, expected)

        _ ->
          false
      end

    if authorized,
      do: conn,
      else: conn |> send_resp(401, "Unauthorized") |> halt()
  end
end
