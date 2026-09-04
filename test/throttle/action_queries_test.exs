defmodule Throttle.ActionQueriesTest do
  # Claim/config/expiration scenarios retained against the new database API.
  use Throttle.DataCase
  import Throttle.DispatchFixtures
  alias Throttle.{DispatchStore, Repo}
  alias Throttle.Schemas.ActionExecution

  test "callback uniqueness prevents duplicate rows before they can be dispatched" do
    first = admit("unique")
    assert admit("unique").id == first.id
    {:ok, batch} = DispatchStore.claim(901)
    DispatchStore.finish(batch, :ok)
    assert admit("unique").processed
  end

  test "claims are leased atomically so another instance cannot select the portal" do
    admit("a")
    admit("b")
    {:ok, batch} = DispatchStore.claim(901)
    assert length(batch.actions) == 2
    assert {:ok, nil} = DispatchStore.claim(901)
    assert Enum.all?(DispatchStore.owned_actions(batch), &(&1.claim_token == batch.token))
  end

  test "terminal rows cannot be revived by an old claim completion" do
    action = admit("terminal")
    {:ok, batch} = DispatchStore.claim(901)
    DispatchStore.finish(batch, {:permanent, "invalid_callback"})
    assert {:error, :stale_claim} = DispatchStore.finish(batch, :ok)
    terminal = Repo.get!(ActionExecution, action.id)
    assert terminal.permanently_failed and not terminal.processed
  end

  test "dispatch eligibility excludes processed failed and expired rows" do
    for cb <- ["processed", "failed", "expired", "valid"], do: admit(cb, %{max_throughput: "4"})
    {:ok, batch} = DispatchStore.claim(901)

    Repo.update_all(from(a in ActionExecution, where: a.callback_id == "processed"),
      set: [processed: true]
    )

    Repo.update_all(from(a in ActionExecution, where: a.callback_id == "failed"),
      set: [permanently_failed: true]
    )

    Repo.update_all(from(a in ActionExecution, where: a.callback_id == "expired"),
      set: [expires_at: DateTime.utc_now() |> DateTime.add(-1) |> DateTime.truncate(:second)]
    )

    assert Enum.map(DispatchStore.owned_actions(batch), & &1.callback_id) == ["valid"]
  end

  test "rate-limit holds remain effective under a non-UTC database session" do
    Repo.query!("SET LOCAL TIME ZONE 'America/Chicago'")
    admit("rate-limited")
    {:ok, batch} = DispatchStore.claim(901)
    DispatchStore.finish(batch, {:rate_limited, 60})
    assert DispatchStore.ready_portals(16) == []
    row = Repo.get!(ActionExecution, hd(batch.actions).id)
    assert DateTime.diff(row.on_hold_until, DateTime.utc_now()) in 59..60
  end

  test "latest configuration survives processing of its source action" do
    admit("old", %{max_throughput: "1"})
    newest = admit("new", %{max_throughput: "7"})
    Repo.update_all(from(a in ActionExecution, where: a.id == ^newest.id), set: [processed: true])
    assert %{rows: [[7]]} = Repo.query!("SELECT max_throughput FROM dispatch_queues")
  end
end
