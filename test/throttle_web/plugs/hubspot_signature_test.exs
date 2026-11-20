defmodule ThrottleWeb.Plugs.HubSpotSignatureTest do
  use ThrottleWeb.ConnCase, async: false

  alias ThrottleWeb.Plugs.HubSpotSignature

  @secret "test-client-secret"
  @body ~s({"callbackId":"cb-1"})
  @path "/api/hubspot/action"

  setup do
    previous_secret = Application.get_env(:throttle, :hubspot_client_secret)
    Application.put_env(:throttle, :hubspot_client_secret, @secret)

    on_exit(fn ->
      if is_nil(previous_secret) do
        Application.delete_env(:throttle, :hubspot_client_secret)
      else
        Application.put_env(:throttle, :hubspot_client_secret, previous_secret)
      end
    end)

    :ok
  end

  defp v3_signature(method, uri, body, timestamp, secret \\ @secret) do
    :crypto.mac(:hmac, :sha256, secret, method <> uri <> body <> timestamp)
    |> Base.encode64()
  end

  defp v2_signature(method, uri, body, secret \\ @secret) do
    :crypto.hash(:sha256, secret <> method <> uri <> body)
    |> Base.encode16(case: :lower)
  end

  defp signed_conn(path \\ @path, headers) do
    conn =
      build_conn(:post, path, @body)
      |> Map.put(:host, "throttler-app.cartermckay.com")
      |> Map.put(:port, 10000)
      |> assign(:raw_body, @body)
      |> put_req_header("x-forwarded-proto", "https")

    Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
  end

  test "accepts a valid v3 signature with fresh timestamp behind TLS proxy" do
    ts = Integer.to_string(System.system_time(:millisecond))
    uri = "https://throttler-app.cartermckay.com#{@path}"

    conn =
      signed_conn([
        {"x-hubspot-signature-v3", v3_signature("POST", uri, @body, ts)},
        {"x-hubspot-request-timestamp", ts}
      ])
      |> HubSpotSignature.call([])

    refute conn.halted
  end

  test "normalizes HubSpot v3 URI characters before verifying signature" do
    ts = Integer.to_string(System.system_time(:millisecond))
    raw_path = "/api/hubspot/action?email=user%40example.com&next=https%3A%2F%2Fexample.com"

    normalized_uri =
      "https://throttler-app.cartermckay.com/api/hubspot/action?email=user@example.com&next=https://example.com"

    conn =
      signed_conn(raw_path, [
        {"x-hubspot-signature-v3", v3_signature("POST", normalized_uri, @body, ts)},
        {"x-hubspot-request-timestamp", ts}
      ])
      |> HubSpotSignature.call([])

    refute conn.halted
  end

  test "rejects expired v3 timestamp even when a valid v2 signature is also present" do
    expired_ts = Integer.to_string(System.system_time(:millisecond) - 400_000)
    uri = "https://throttler-app.cartermckay.com#{@path}"

    conn =
      signed_conn([
        {"x-hubspot-signature-v3", v3_signature("POST", uri, @body, expired_ts)},
        {"x-hubspot-request-timestamp", expired_ts},
        {"x-hubspot-signature", v2_signature("POST", uri, @body)}
      ])
      |> HubSpotSignature.call([])

    assert conn.halted
    assert conn.status == 401
    assert %{"detail" => detail} = Jason.decode!(conn.resp_body)
    assert detail =~ "timestamp expired"
  end

  test "rejects mismatched v3 signature even when a valid v2 signature is also present" do
    ts = Integer.to_string(System.system_time(:millisecond))
    uri = "https://throttler-app.cartermckay.com#{@path}"

    conn =
      signed_conn([
        {"x-hubspot-signature-v3", "not-a-valid-v3-signature"},
        {"x-hubspot-request-timestamp", ts},
        {"x-hubspot-signature", v2_signature("POST", uri, @body)}
      ])
      |> HubSpotSignature.call([])

    assert conn.halted
    assert conn.status == 401
    assert %{"detail" => "signature mismatch"} = Jason.decode!(conn.resp_body)
  end

  test "rejects v3 request missing timestamp even when a valid v2 signature is present" do
    uri = "https://throttler-app.cartermckay.com#{@path}"

    conn =
      signed_conn([
        {"x-hubspot-signature-v3", "some-signature"},
        {"x-hubspot-signature", v2_signature("POST", uri, @body)}
      ])
      |> HubSpotSignature.call([])

    assert conn.halted
    assert conn.status == 401

    assert %{"detail" => "missing x-hubspot-request-timestamp header"} =
             Jason.decode!(conn.resp_body)
  end

  test "accepts legacy v2-only request when v3 header is absent" do
    uri = "https://throttler-app.cartermckay.com#{@path}"

    conn =
      signed_conn([
        {"x-hubspot-signature", v2_signature("POST", uri, @body)}
      ])
      |> HubSpotSignature.call([])

    refute conn.halted
  end

  test "rejects v2 request with expired timestamp header when v3 header is stripped" do
    expired_ts = Integer.to_string(System.system_time(:millisecond) - 400_000)
    uri = "https://throttler-app.cartermckay.com#{@path}"

    conn =
      signed_conn([
        {"x-hubspot-request-timestamp", expired_ts},
        {"x-hubspot-signature", v2_signature("POST", uri, @body)}
      ])
      |> HubSpotSignature.call([])

    assert conn.halted
    assert conn.status == 401
  end

  test "rejects request when client secret is not configured" do
    Application.delete_env(:throttle, :hubspot_client_secret)

    conn =
      signed_conn([])
      |> HubSpotSignature.call([])

    assert conn.halted
    assert conn.status == 401
  end
end
