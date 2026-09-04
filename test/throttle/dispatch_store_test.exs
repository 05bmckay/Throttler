defmodule Throttle.DispatchStoreTest do
  use Throttle.DataCase
  import Throttle.DispatchFixtures
  alias Throttle.{DispatchStore, Repo}
  alias Throttle.Schemas.ActionExecution

  test "daily allowance survives a new claimant and completed actions" do
    for n <- 1..5, do: admit("daily-#{n}", %{period: "days"})
    {:ok, batch} = DispatchStore.claim(901)
    assert length(batch.actions) == 2
    assert {:ok, _} = DispatchStore.finish(batch, :ok)
    assert {:ok, nil} = DispatchStore.claim(901)
    due()
    assert {:ok, next} = DispatchStore.claim(901)
    assert length(next.actions) == 2
  end

  test "another instance cannot claim while a portal delivery is in flight" do
    admit("exclusive")
    assert {:ok, batch} = DispatchStore.claim(901)
    assert batch != nil
    assert {:ok, nil} = DispatchStore.claim(901)
    assert DispatchStore.ready_portals(16) == []
  end

  test "large reservation drains in API sized chunks but excludes new arrivals" do
    for n <- 1..205, do: admit("large-#{n}", %{max_throughput: "250", period: "days"})
    {:ok, first} = DispatchStore.claim(901)
    assert length(first.actions) == 100
    DispatchStore.finish(first, :ok)
    admit("later", %{max_throughput: "250", period: "days"})
    {:ok, second} = DispatchStore.claim(901)
    assert length(second.actions) == 100
    DispatchStore.finish(second, :ok)
    {:ok, third} = DispatchStore.claim(901)
    assert length(third.actions) == 5
    DispatchStore.finish(third, :ok)
    assert {:ok, nil} = DispatchStore.claim(901)
  end

  test "stale owner cannot dispatch or complete after lease reclamation" do
    admit("fencing")
    {:ok, old} = DispatchStore.claim(901)
    Repo.query!("UPDATE dispatch_portals SET lease_until=now()-interval '1 second'")
    Repo.update_all(ActionExecution, set: [on_hold_until: DateTime.add(DateTime.utc_now(), -1)])
    {:ok, replacement} = DispatchStore.claim(901)
    assert replacement.token != old.token
    assert DispatchStore.owned_actions(old) == []
    assert {:error, :stale_claim} = DispatchStore.finish(old, :ok)
    refute Repo.get!(ActionExecution, hd(old.actions).id).processed
    assert {:ok, _} = DispatchStore.finish(replacement, :ok)
  end

  test "429 persists portal-wide cooldown and retains the rate reservation" do
    admit("limited", %{period: "days"})
    {:ok, batch} = DispatchStore.claim(901)
    DispatchStore.finish(batch, {:rate_limited, 60})
    assert {:ok, nil} = DispatchStore.claim(901)
    assert DispatchStore.ready_portals(16) == []
    Repo.query!("UPDATE dispatch_portals SET available_at=now()-interval '1 second'")
    Repo.update_all(ActionExecution, set: [on_hold_until: DateTime.add(DateTime.utc_now(), -1)])
    {:ok, retry} = DispatchStore.claim(901)
    assert Enum.map(retry.actions, & &1.id) == Enum.map(batch.actions, & &1.id)
  end

  test "transient failure has one attempt owner and no new rate charge" do
    admit("retry", %{period: "days"})
    {:ok, batch} = DispatchStore.claim(901)
    DispatchStore.finish(batch, {:retry, "transport"})
    row = Repo.get!(ActionExecution, hd(batch.actions).id)
    assert row.total_attempts == 1 and row.rate_reserved
    assert {:ok, nil} = DispatchStore.claim(901)
    Repo.update_all(ActionExecution, set: [on_hold_until: DateTime.add(DateTime.utc_now(), -1)])
    assert {:ok, retry} = DispatchStore.claim(901)
    assert retry != nil
  end

  test "expiration between claim and send prevents HTTP eligibility and success" do
    admit("expired")
    {:ok, batch} = DispatchStore.claim(901)

    Repo.update_all(ActionExecution,
      set: [expires_at: DateTime.utc_now() |> DateTime.add(-1) |> DateTime.truncate(:second)]
    )

    assert DispatchStore.owned_actions(batch) == []
    DispatchStore.finish(batch, :ok)
    refute Repo.get!(ActionExecution, hd(batch.actions).id).processed
    assert {1, _} = DispatchStore.expire()
    assert Repo.get!(ActionExecution, hd(batch.actions).id).permanently_failed
  end

  test "twentieth transient failure becomes terminal instead of retrying forever" do
    action = admit("retry-cap")

    Repo.update_all(from(a in ActionExecution, where: a.id == ^action.id),
      set: [total_attempts: 19]
    )

    {:ok, batch} = DispatchStore.claim(901)
    assert {:ok, _} = DispatchStore.finish(batch, {:retry, "transport"})
    row = Repo.get!(ActionExecution, action.id)
    assert row.total_attempts == 20
    assert row.permanently_failed and row.completed_at != nil
    assert {:ok, nil} = DispatchStore.claim(901)
  end
end
