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

  test "bad multi-callback request isolates callbacks instead of failing every row" do
    stub([HTTPStub.response(400)])
    admit("good-maybe")
    admit("bad-maybe")
    {:ok, batch} = DispatchStore.claim(901)
    assert {:isolate, "callback_http_400"} = Delivery.run(batch)
    assert Repo.aggregate(from(a in ActionExecution, where: a.permanently_failed), :count) == 0
    Repo.update_all(ActionExecution, set: [on_hold_until: DateTime.add(DateTime.utc_now(), -1)])
    {:ok, isolated} = DispatchStore.claim(901)
    assert length(isolated.actions) == 1
  end

  defp stub(responses),
    do: start_supervised!(%{id: HTTPStub, start: {HTTPStub, :start_link, [responses]}})
end
