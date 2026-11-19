defmodule Throttle.PortalQueueTest do
  # Retains portal-delivery scenarios from the former in-memory queue and adds
  # real HTTP-result transitions using a transport that cannot reach HubSpot.
  use Throttle.DataCase
  import Throttle.DispatchFixtures
  alias Throttle.{DispatchStore, Delivery, HTTPStub, Repo}
  alias Throttle.Schemas.{ActionExecution, SecureOAuthToken}

  setup do
    previous = Application.get_env(:throttle, :http_adapter)
    Application.put_env(:throttle, :http_adapter, HTTPStub)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:throttle, :http_adapter, previous),
        else: Application.delete_env(:throttle, :http_adapter)
    end)

    %SecureOAuthToken{}
    |> SecureOAuthToken.changeset(%{
      portal_id: 901,
      access_token: "fake-access",
      refresh_token: "fake-refresh",
      token_response: %{"hub_id" => 901},
      expires_at: DateTime.add(DateTime.utc_now(), 3600)
    })
    |> Repo.insert!()

    :ok
  end

  test "delivers an idle portal immediately and leaves a durable remainder" do
    stub([HTTPStub.response(204)])
    for n <- 1..150, do: admit("delivery-#{n}", %{max_throughput: "150"})
    {:ok, batch} = DispatchStore.claim(901)
    assert :ok = Delivery.run(batch)
    assert Repo.aggregate(from(a in ActionExecution, where: a.processed), :count) == 100
    {:ok, next} = DispatchStore.claim(901)
    assert length(next.actions) == 50
  end

  test "completed rows are excluded before delivery" do
    admit("already-done")
    {:ok, batch} = DispatchStore.claim(901)
    Repo.update_all(ActionExecution, set: [processed: true])
    assert {:retry, "stale_claim"} = Delivery.run(batch)
    assert Repo.get!(ActionExecution, hd(batch.actions).id).total_attempts == 0
  end

  test "401 refreshes once and retries with the new token" do
    stub([
      HTTPStub.response(401),
      HTTPStub.response(
        200,
        Jason.encode!(%{access_token: "new-fake", refresh_token: "new-refresh", expires_in: 1800})
      ),
      HTTPStub.response(204)
    ])

    admit("refresh")
    {:ok, batch} = DispatchStore.claim(901)
    assert :ok = Delivery.run(batch)
    requests = HTTPStub.requests()
    assert length(requests) == 3
    assert {"Authorization", "Bearer new-fake"} in List.last(requests).headers
  end

  test "429 honors case-insensitive Retry-After without sleeping or retry loops" do
    stub([HTTPStub.response(429, "", [{"Retry-After", "60"}])])
    admit("limited")
    {:ok, batch} = DispatchStore.claim(901)
    assert {:rate_limited, 60} = Delivery.run(batch)
    assert length(HTTPStub.requests()) == 1
    assert {:ok, nil} = DispatchStore.claim(901)
  end

  test "transient 503 attempts once and records one durable retry" do
    stub([HTTPStub.response(503)])
    admit("server-error")
    {:ok, batch} = DispatchStore.claim(901)
    assert {:retry, "callback_http_503"} = Delivery.run(batch)
    assert length(HTTPStub.requests()) == 1
    assert Repo.get!(ActionExecution, hd(batch.actions).id).total_attempts == 1
  end

  test "bad multi-callback request on a full daily queue isolates immediately without waiting a day" do
    stub([HTTPStub.response(400), HTTPStub.response(204), HTTPStub.response(400)])
    for n <- 1..4, do: admit("iso-#{n}", %{max_throughput: "2", period: "days"})
    {:ok, batch} = DispatchStore.claim(901)
    assert length(batch.actions) == 2
    assert {:isolate, "callback_http_400"} = Delivery.run(batch)
    assert Repo.aggregate(from(a in ActionExecution, where: a.permanently_failed), :count) == 0

    # No due() and no manual on_hold_until clearing: isolated retries run 1-by-1 immediately.
    {:ok, first_iso} = DispatchStore.claim(901)
    assert length(first_iso.actions) == 1
    assert hd(first_iso.actions).callback_id == "iso-1"
    assert :ok = Delivery.run(first_iso)

    {:ok, second_iso} = DispatchStore.claim(901)
    assert length(second_iso.actions) == 1
    assert hd(second_iso.actions).callback_id == "iso-2"
    assert {:permanent, "callback_http_400"} = Delivery.run(second_iso)

    # Full daily allowance (2) is now consumed; iso-3 and iso-4 wait for day 2.
    assert {:ok, nil} = DispatchStore.claim(901)
  end

  test "400 uses actual owned count when another row completed before send" do
    stub([HTTPStub.response(400)])
    first = admit("sent-1")
    admit("sent-2")
    {:ok, batch} = DispatchStore.claim(901)
    Repo.update_all(from(a in ActionExecution, where: a.id == ^first.id), set: [processed: true])
    assert {:permanent, "callback_http_400"} = Delivery.run(batch)
  end

  test "pre-HTTP OAuth failure backs off portal, refunds daily budget, and resumes upon re-authorization" do
    Repo.delete_all(SecureOAuthToken)

    stub([
      HTTPStub.response(200, Jason.encode!(%{"hub_id" => 901, "user" => "user@example.com"})),
      HTTPStub.response(204)
    ])

    for n <- 1..4, do: admit("auth-#{n}", %{max_throughput: "2", period: "days"})
    {:ok, batch} = DispatchStore.claim(901)
    assert {:auth_retry, "token_not_found"} = Delivery.run(batch)

    # Portal is backed off so fresh actions cannot steal the refunded budget.
    assert {:ok, nil} = DispatchStore.claim(901)
    assert DispatchStore.ready_portals(16) == []

    # Re-authenticating releases the auth hold immediately.
    assert {:ok, _} =
             Throttle.OAuthManager.store_token(%{
               "access_token" => "reauth-access",
               "refresh_token" => "reauth-refresh",
               "expires_in" => 1800
             })

    {:ok, retry} = DispatchStore.claim(901)
    assert Enum.map(retry.actions, & &1.id) == Enum.map(batch.actions, & &1.id)
    assert :ok = Delivery.run(retry)
    assert {:ok, nil} = DispatchStore.claim(901)
  end

  test "malformed OAuth refresh JSON fails cleanly as auth_retry instead of crashing" do
    Repo.update_all(from(t in SecureOAuthToken, where: t.portal_id == 901),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -10)]
    )

    stub([HTTPStub.response(200, Jason.encode!(%{"unexpected" => true}))])
    admit("malformed-refresh", %{max_throughput: "1", period: "days"})
    {:ok, batch} = DispatchStore.claim(901)
    assert {:auth_retry, "token_refresh_failed"} = Delivery.run(batch)
  end

  defp stub(responses),
    do: start_supervised!(%{id: HTTPStub, start: {HTTPStub, :start_link, [responses]}})
end
