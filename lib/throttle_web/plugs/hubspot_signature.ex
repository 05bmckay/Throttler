defmodule ThrottleWeb.Plugs.HubSpotSignature do
  import Plug.Conn
  require Logger

  @behaviour Plug

  @max_timestamp_drift_ms 300_000

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if signature_verification_disabled?() do
      Logger.warning("HubSpot signature verification disabled via HUBSPOT_SKIP_SIGNATURE=true")
      conn
    else
      case get_client_secret() do
        nil ->
          Logger.error("HubSpot client secret not configured — rejecting request")
          reject(conn, "server misconfiguration: client secret not set")

        secret ->
          verify_signature(conn, secret)
      end
    end
  end

  defp verify_signature(conn, secret) do
    case get_req_header(conn, "x-hubspot-signature-v3") do
      [v3_sig | _] -> verify_v3(conn, secret, v3_sig)
      [] -> verify_v2(conn, secret)
    end
  end

  # v3: HMAC-SHA256(secret, method + normalized_URI + body + timestamp) → base64
  # Never fall back to v2 when v3 is present; otherwise an expired timestamp or
  # forged v3 header would bypass replay protection whenever HubSpot also sends v2.
  defp verify_v3(conn, secret, expected_signature) do
    with {:ok, timestamp} <- get_header(conn, "x-hubspot-request-timestamp"),
         :ok <- validate_timestamp(timestamp) do
      raw_body = conn.assigns[:raw_body] || ""
      uri = conn |> full_request_url() |> decode_v3_uri()
      source_string = conn.method <> uri <> raw_body <> timestamp

      computed =
        :crypto.mac(:hmac, :sha256, secret, source_string)
        |> Base.encode64()

      if Plug.Crypto.secure_compare(computed, expected_signature) do
        conn
      else
        Logger.warning(
          "HubSpot v3 signature verification failed: signature mismatch (url: #{uri})"
        )

        reject(conn, "signature mismatch")
      end
    else
      {:error, reason} ->
        Logger.warning("HubSpot v3 signature verification failed: #{reason}")
        reject(conn, reason)
    end
  end

  # v2: SHA-256(secret + method + URI + body) → hex
  # Only accepted when x-hubspot-signature-v3 is absent. If a timestamp header is
  # present, still enforce drift so stripping only the v3 header cannot replay old requests.
  defp verify_v2(conn, secret) do
    with :ok <- validate_optional_timestamp(conn),
         {:ok, expected_signature} <- get_header(conn, "x-hubspot-signature") do
      raw_body = conn.assigns[:raw_body] || ""
      uri = full_request_url(conn)
      source_string = secret <> conn.method <> uri <> raw_body

      computed =
        :crypto.hash(:sha256, source_string)
        |> Base.encode16(case: :lower)

      if Plug.Crypto.secure_compare(computed, expected_signature) do
        Logger.warning(
          "Accepted legacy HubSpot v2 signature without x-hubspot-signature-v3 header"
        )

        conn
      else
        Logger.warning("HubSpot signature verification failed: signature mismatch (url: #{uri})")

        reject(conn, "signature mismatch")
      end
    else
      {:error, reason} ->
        Logger.warning("HubSpot signature verification failed: #{reason}")
        reject(conn, reason)
    end
  end

  defp validate_optional_timestamp(conn) do
    case get_req_header(conn, "x-hubspot-request-timestamp") do
      [timestamp | _] -> validate_timestamp(timestamp)
      [] -> :ok
    end
  end

  @v3_uri_replacements [
    {"%3A", ":"},
    {"%2F", "/"},
    {"%3F", "?"},
    {"%40", "@"},
    {"%21", "!"},
    {"%24", "$"},
    {"%27", "'"},
    {"%28", "("},
    {"%29", ")"},
    {"%2A", "*"},
    {"%2C", ","},
    {"%3B", ";"}
  ]

  defp decode_v3_uri(uri) do
    Enum.reduce(@v3_uri_replacements, uri, fn {encoded, decoded}, acc ->
      acc
      |> String.replace(encoded, decoded)
      |> String.replace(String.downcase(encoded), decoded)
    end)
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

  defp full_request_url(conn) do
    forwarded_proto = get_req_header(conn, "x-forwarded-proto") |> List.first()
    scheme = to_string(forwarded_proto || conn.scheme)
    host = conn.host
    path = conn.request_path
    query = if conn.query_string != "", do: "?" <> conn.query_string, else: ""

    # Behind a reverse proxy, conn.port is the internal port (e.g. 4000).
    # When x-forwarded-proto is present, use default port for that scheme.
    port_suffix =
      if forwarded_proto do
        ""
      else
        case {scheme, conn.port} do
          {"https", 443} -> ""
          {"http", 80} -> ""
          {_, p} -> ":#{p}"
        end
      end

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

  defp signature_verification_disabled? do
    System.get_env("HUBSPOT_SKIP_SIGNATURE") == "true" and
      Application.get_env(:throttle, :env) in [:dev, :test]
  end
end
