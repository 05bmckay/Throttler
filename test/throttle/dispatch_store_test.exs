defmodule Throttle.DispatchStoreTest do
  use Throttle.DataCase
  import Throttle.DispatchFixtures
  alias Throttle.{DispatchStore, Repo}
  alias Throttle.Schemas.ActionExecution

  test "expired deliveries in two workflows recover without doubling their 15-record allowance" do
    queues = ["queue:901:902:903:0", "queue:901:904:903:0"]

    for queue <- queues, n <- 1..45 do
      admit("recovery-#{queue}-#{n}", %{queue_id: queue, max_throughput: "15"})
    end

    {:ok, abandoned} = DispatchStore.claim(901)
    assert Enum.frequencies_by(abandoned.actions, & &1.queue_id) == Map.new(queues, &{&1, 15})

    Repo.query!("UPDATE dispatch_portals SET lease_until=now()-interval '1 second'")
    Repo.update_all(ActionExecution, set: [on_hold_until: DateTime.add(DateTime.utc_now(), -1)])
    for queue <- queues, do: due(queue)

    {:ok, recovered} = DispatchStore.claim(901)
    assert Enum.frequencies_by(recovered.actions, & &1.queue_id) == Map.new(queues, &{&1, 15})
    assert MapSet.new(recovered.actions, & &1.id) == MapSet.new(abandoned.actions, & &1.id)
    assert {:error, :stale_claim} = DispatchStore.finish(abandoned, :ok)
    assert {:ok, _} = DispatchStore.finish(recovered, :ok)
    assert {:ok, nil} = DispatchStore.claim(901)
    assert DispatchStore.ready_portals(16) == []

    for queue <- queues, do: due(queue)
    {:ok, fresh} = DispatchStore.claim(901)
    assert Enum.frequencies_by(fresh.actions, & &1.queue_id) == Map.new(queues, &{&1, 15})

    assert MapSet.disjoint?(
             MapSet.new(fresh.actions, & &1.id),
             MapSet.new(recovered.actions, & &1.id)
           )
  end

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

  test "retry waits for delivery capacity without spending a fresh reservation" do
    for n <- 1..3, do: admit("retry-budget-#{n}", %{max_throughput: "1", period: "days"})
    {:ok, first} = DispatchStore.claim(901)
    assert {:ok, _} = DispatchStore.finish(first, {:retry, "transport"})
    Repo.update_all(ActionExecution, set: [on_hold_until: DateTime.add(DateTime.utc_now(), -1)])
    assert {:ok, nil} = DispatchStore.claim(901)
    assert DispatchStore.ready_portals(16) == []

    # Advance delivery window: the retry runs first and consumes the full window
    # without letting fresh work through in the same day.
    Repo.query!("UPDATE dispatch_queues SET delivery_window_until=now()-interval '1 second'")
    {:ok, retry} = DispatchStore.claim(901)
    assert Enum.map(retry.actions, & &1.id) == Enum.map(first.actions, & &1.id)
    assert {:ok, _} = DispatchStore.finish(retry, :ok)
    assert {:ok, nil} = DispatchStore.claim(901)
    assert DispatchStore.ready_portals(16) == []
  end

  test "partial first window allows subsequent arrivals up to the full daily allowance" do
    # Reproduces bulk enrollment arriving over multiple seconds into a new 50/day queue:
    # 3 arrive first, then 117 more arrive moments later.
    for n <- 1..3,
        do: admit("bulk-#{n}", %{max_throughput: "50", time: "1", period: "days"})

    {:ok, first} = DispatchStore.claim(901)
    assert length(first.actions) == 3
    assert {:ok, _} = DispatchStore.finish(first, :ok)

    %{rows: [[initial_window, 3]]} =
      Repo.query!("SELECT delivery_window_until, delivery_count FROM dispatch_queues")

    for n <- 4..120,
        do: admit("bulk-#{n}", %{max_throughput: "50", time: "1", period: "days"})

    {:ok, rest_of_day_one} = DispatchStore.claim(901)
    assert length(rest_of_day_one.actions) == 47
    assert {:ok, _} = DispatchStore.finish(rest_of_day_one, :ok)

    # Window deadline stays anchored to the first send; remaining 70 wait for day 2.
    assert %{rows: [[^initial_window, 50]]} =
             Repo.query!("SELECT delivery_window_until, delivery_count FROM dispatch_queues")

    assert {:ok, nil} = DispatchStore.claim(901)
    assert DispatchStore.ready_portals(16) == []

    due()
    {:ok, day_two} = DispatchStore.claim(901)
    assert length(day_two.actions) == 50
    assert {:ok, _} = DispatchStore.finish(day_two, :ok)
    assert {:ok, nil} = DispatchStore.claim(901)

    due()
    {:ok, day_three} = DispatchStore.claim(901)
    assert length(day_three.actions) == 20
    assert {:ok, _} = DispatchStore.finish(day_three, :ok)
    assert {:ok, nil} = DispatchStore.claim(901)
  end

  test "organic one-by-one arrivals use the full configured window before blocking" do
    for n <- 1..3 do
      admit("trickle-#{n}", %{max_throughput: "3", period: "days"})
      {:ok, batch} = DispatchStore.claim(901)
      assert length(batch.actions) == 1
      assert {:ok, _} = DispatchStore.finish(batch, :ok)
    end

    admit("trickle-4", %{max_throughput: "3", period: "days"})
    assert {:ok, nil} = DispatchStore.claim(901)
    assert DispatchStore.ready_portals(16) == []
  end

  test "mixed fresh and recovered actions share the same delivery allowance" do
    for n <- 1..8, do: admit("mixed-#{n}", %{max_throughput: "3"})
    {:ok, first} = DispatchStore.claim(901)
    assert {:ok, _} = DispatchStore.finish(first, {:retry, "transport"})

    # Only one old callback is ready to retry; the other two remain on hold.
    Repo.update_all(from(a in ActionExecution, where: a.id == ^hd(first.actions).id),
      set: [on_hold_until: DateTime.add(DateTime.utc_now(), -1)]
    )

    due()
    {:ok, mixed} = DispatchStore.claim(901)
    assert length(mixed.actions) == 3
    assert Enum.count(mixed.actions, & &1.rate_reserved) == 1
    assert {:ok, _} = DispatchStore.finish(mixed, :ok)
    # A remaining fresh reservation cannot bypass the spent delivery budget.
    assert {:ok, nil} = DispatchStore.claim(901)
  end

  test "lowering throughput cannot reset an already spent delivery allowance" do
    for n <- 1..6, do: admit("lower-#{n}", %{max_throughput: "3", period: "days"})
    {:ok, first} = DispatchStore.claim(901)
    assert {:ok, _} = DispatchStore.finish(first, :ok)
    admit("lower-new", %{max_throughput: "1", period: "days"})
    assert {:ok, nil} = DispatchStore.claim(901)
    assert DispatchStore.ready_portals(16) == []
    due()
    {:ok, next} = DispatchStore.claim(901)
    assert length(next.actions) == 1
  end

  test "another instance cannot claim while a portal delivery is in flight" do
    admit("exclusive")
    assert {:ok, batch} = DispatchStore.claim(901)
    assert batch != nil
    assert {:ok, nil} = DispatchStore.claim(901)
    assert DispatchStore.ready_portals(16) == []
  end

  test "large window allowance drains in API sized chunks and caps at max_throughput" do
    for n <- 1..205, do: admit("large-#{n}", %{max_throughput: "250", period: "days"})
    {:ok, first} = DispatchStore.claim(901)
    assert length(first.actions) == 100
    DispatchStore.finish(first, :ok)

    for n <- 206..265, do: admit("large-#{n}", %{max_throughput: "250", period: "days"})
    {:ok, second} = DispatchStore.claim(901)
    assert length(second.actions) == 100
    DispatchStore.finish(second, :ok)

    {:ok, third} = DispatchStore.claim(901)
    assert length(third.actions) == 50
    DispatchStore.finish(third, :ok)

    assert {:ok, nil} = DispatchStore.claim(901)
    assert DispatchStore.ready_portals(16) == []
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

  test "429 on a full daily batch refunds window budget and retries after cooldown without letting fresh work jump ahead" do
    for n <- 1..4, do: admit("limited-#{n}", %{max_throughput: "2", period: "days"})
    {:ok, batch} = DispatchStore.claim(901)
    assert length(batch.actions) == 2
    DispatchStore.finish(batch, {:rate_limited, 60})
    assert {:ok, nil} = DispatchStore.claim(901)
    assert DispatchStore.ready_portals(16) == []

    # Release only the 429 cooldown — do NOT advance delivery_window_until.
    Repo.query!(
      "UPDATE dispatch_portals SET available_at=timezone('UTC', now())-interval '1 second'"
    )

    Repo.update_all(ActionExecution, set: [on_hold_until: DateTime.add(DateTime.utc_now(), -1)])
    {:ok, retry} = DispatchStore.claim(901)
    assert Enum.map(retry.actions, & &1.id) == Enum.map(batch.actions, & &1.id)
    assert {:ok, _} = DispatchStore.finish(retry, :ok)
    # Remaining 2 fresh items must still wait for the next daily window.
    assert {:ok, nil} = DispatchStore.claim(901)
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
