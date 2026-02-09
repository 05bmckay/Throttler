defmodule ThrottleWeb.Plugs.HubSpotSignature do
  @moduledoc """
  Plug that verifies HubSpot webhook v2 signatures.

  ## Algorithm (v2)

      signature = hex(hmac_sha256(client_secret, METHOD + URI + request_body + timestamp))

  The plug reads the following headers:
    - `X-HubSpot-Signature-Version` — must be `"v2"`
    - `X-HubSpot-Signature` — the hex-encoded HMAC-SHA256 signature
    - `X-HubSpot-Request-Timestamp` — millisecond Unix timestamp

  The raw request body is expected in `conn.assigns[:raw_body]`, cached by
  `ThrottleWeb.CacheBodyReader`.

  ## Configuration

  The client secret is read from:

      Application.get_env(:throttle, :hubspot_client_secret)

  If no secret is configured, requests are allowed through (development bypass).
  """

  import Plug.Conn
  require Logger

  @behaviour Plug

  @max_timestamp_drift_ms 300_000

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case get_client_secret() do
      nil ->
        Logger.warning("HubSpot client secret not configured — skipping signature verification")
        conn

      secret ->
        verify_signature(conn, secret)
    end
  end

  defp verify_signature(conn, secret) do
    with {:ok, signature} <- get_header(conn, "x-hubspot-signature"),
         {:ok, timestamp} <- get_header(conn, "x-hubspot-request-timestamp"),
         :ok <- validate_timestamp(timestamp),
         :ok <- check_signature(conn, secret, signature, timestamp) do
      conn
    else
      {:error, reason} ->
        Logger.warning("HubSpot signature verification failed: #{reason}")
        reject(conn, reason)
    end
  end

  defp get_header(conn, header) do
    case get_req_header(conn, header) do
      [value | _] -> {:ok, value}
      [] -> {:error, "missing #{header} header"}
    end
  end

  defp validate_timestamp(timestamp_str) do
    case Integer.parse(timestamp_str) do
      {timestamp_ms, ""} ->
        now_ms = System.system_time(:millisecond)
        drift = abs(now_ms - timestamp_ms)

        if drift <= @max_timestamp_drift_ms do
          :ok
        else
          {:error, "timestamp expired (drift: #{drift}ms)"}
        end

      _ ->
        {:error, "invalid timestamp format"}
    end
  end

  defp check_signature(conn, secret, expected_signature, timestamp) do
    raw_body = conn.assigns[:raw_body] || ""
    method = conn.method
    uri = full_request_url(conn)

    source_string = method <> uri <> raw_body <> timestamp

    computed =
      :crypto.mac(:hmac, :sha256, secret, source_string)
      |> Base.encode16(case: :lower)

    if Plug.Crypto.secure_compare(computed, expected_signature) do
      :ok
    else
      {:error, "signature mismatch"}
    end
  end

  defp full_request_url(conn) do
    # Reconstruct the full URL as HubSpot sees it.
    # Use the request path + query string. HubSpot sends the full URL
    # (scheme + host + path + query) in its signature computation.
    # We reconstruct from conn fields to match what HubSpot computed.
    scheme =
      to_string(
        Plug.Conn.get_req_header(conn, "x-forwarded-proto") |> List.first() || conn.scheme
      )

    host = conn.host
    port = conn.port

    port_suffix =
      case {scheme, port} do
        {"https", 443} -> ""
        {"http", 80} -> ""
        {_, p} -> ":#{p}"
      end

    path = conn.request_path
    query = if conn.query_string != "", do: "?" <> conn.query_string, else: ""

    "#{scheme}://#{host}#{port_suffix}#{path}#{query}"
  end

  defp reject(conn, reason) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "Unauthorized", detail: reason}))
    |> halt()
  end

  defp get_client_secret do
    Application.get_env(:throttle, :hubspot_client_secret)
  end
end
