defmodule Throttle.Workers.DataRetentionWorkerTest do
  use Throttle.DataCase

  alias Throttle.Repo
  alias Throttle.Schemas.ActionExecution
  alias Throttle.Workers.DataRetentionWorker

  test "deletes old processed and permanently failed rows but preserves active work" do
    old =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-31 * 86_400, :second)
      |> NaiveDateTime.truncate(:second)

    recent = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows = [
      execution_attrs("old-processed", old, %{processed: true}),
      execution_attrs("old-expired", old, %{permanently_failed: true}),
      execution_attrs("old-active", old, %{}),
      execution_attrs("recent-terminal", recent, %{permanently_failed: true})
    ]

    assert {4, nil} = Repo.insert_all(ActionExecution, rows)
    assert :ok = DataRetentionWorker.perform(%Oban.Job{})

    remaining = Repo.all(ActionExecution) |> Enum.map(& &1.callback_id) |> Enum.sort()
    assert remaining == ["old-active", "recent-terminal"]
  end

  defp execution_attrs(callback_id, timestamp, overrides) do
    Map.merge(
      %{
        queue_id: "queue:retention:test:0",
        callback_id: callback_id,
        processed: false,
        max_throughput: "1",
        time: "1",
        period: "seconds",
        consecutive_failures: 0,
        total_attempts: 0,
        permanently_failed: false,
        inserted_at: timestamp,
        updated_at: timestamp
      },
      overrides
    )
  end
end
