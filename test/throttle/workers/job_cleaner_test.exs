defmodule Throttle.Workers.JobCleanerTest do
  use Throttle.DataCase
  import Throttle.DispatchFixtures
  alias Throttle.{DispatchStore, Repo}
  alias Throttle.Schemas.ActionExecution

  test "expires overdue callbacks while preserving valid queued work" do
    expired =
      admit("expired", %{
        expires_at: DateTime.utc_now() |> DateTime.add(-1) |> DateTime.truncate(:second)
      })

    valid = admit("valid")
    assert :ok = Throttle.Workers.JobCleaner.perform(%Oban.Job{})
    assert Repo.get!(ActionExecution, expired.id).permanently_failed
    refute Repo.get!(ActionExecution, valid.id).permanently_failed
  end

  test "all runnable portals recover without one-per-cron throttling" do
    admit("one")
    admit("two", %{queue_id: "queue:902:1:1:0"})
    assert Enum.sort(DispatchStore.ready_portals(16)) == [901, 902]
  end

  test "held and terminal work is excluded from recovery" do
    held = admit("held")
    terminal = admit("terminal", %{queue_id: "queue:902:1:1:0"})

    Repo.update_all(from(a in ActionExecution, where: a.id == ^held.id),
      set: [on_hold_until: DateTime.add(DateTime.utc_now(), 3600)]
    )

    Repo.update_all(from(a in ActionExecution, where: a.id == ^terminal.id),
      set: [permanently_failed: true]
    )

    assert DispatchStore.ready_portals(16) == []
  end
end
