defmodule Throttle.ActionQueriesTest do
  use Throttle.DataCase

  alias Throttle.ActionQueries
  alias Throttle.Repo
  alias Throttle.Schemas.ActionExecution

  test "successful callback completion clears every duplicate row" do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      Enum.map(1..2, fn id ->
        %{
          queue_id: "queue:1:2:3:0",
          callback_id: "duplicate-callback",
          processed: false,
          max_throughput: "3",
          time: "1",
          period: "seconds",
          last_failure_reason: "in_flight_#{id}",
          consecutive_failures: id,
          total_attempts: id,
          permanently_failed: false,
          inserted_at: now,
          updated_at: now
        }
      end)

    assert {2, nil} = Repo.insert_all(ActionExecution, rows)

    ActionQueries.mark_callbacks_processed_and_clear_errors(["duplicate-callback"])

    assert [first, second] = Repo.all(ActionExecution)

    for execution <- [first, second] do
      assert execution.processed
      assert is_nil(execution.last_failure_reason)
      assert execution.consecutive_failures == 0
    end
  end

  test "claims are leased atomically so another runner cannot select the same row" do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows = [
      execution_attrs("callback-1", now),
      execution_attrs("callback-2", NaiveDateTime.add(now, 1, :second))
    ]

    assert {2, nil} = Repo.insert_all(ActionExecution, rows)

    assert {:ok, [%ActionExecution{callback_id: "callback-1", id: first_id}]} =
             ActionQueries.get_next_action_batch("queue:claim:test:0", "1")

    assert {:ok, [%ActionExecution{callback_id: "callback-2"}]} =
             ActionQueries.get_next_action_batch("queue:claim:test:0", "1")

    claimed = Repo.get!(ActionExecution, first_id)
    assert claimed.last_failure_reason == "in_flight"
    assert %DateTime{} = claimed.on_hold_until
    assert DateTime.diff(claimed.on_hold_until, DateTime.utc_now(), :second) >= 179
  end

  test "rate-limit deferral reserves callbacks through the retry processing window" do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    attrs = execution_attrs("rate-limited", now)

    assert {1, nil} = Repo.insert_all(ActionExecution, [attrs])
    execution = Repo.get_by!(ActionExecution, callback_id: "rate-limited")

    assert {1, nil} = ActionQueries.defer_rate_limited_actions([execution.id], 60)

    deferred = Repo.reload!(execution)
    assert deferred.last_failure_reason == "rate_limited"
    assert DateTime.diff(deferred.on_hold_until, DateTime.utc_now(), :second) >= 239

    assert {1, nil} = ActionQueries.defer_rate_limited_actions([execution.id], 10)
    assert Repo.reload!(execution).on_hold_until == deferred.on_hold_until
  end

  test "latest configuration wins and expired actions are made terminal" do
    now_utc = DateTime.utc_now() |> DateTime.truncate(:second)
    now = DateTime.to_naive(now_utc)

    old =
      execution_attrs("old-config", now)
      |> Map.merge(%{max_throughput: "1", time: "1", period: "hours"})

    latest =
      execution_attrs("latest-config", NaiveDateTime.add(now, 1, :second))
      |> Map.merge(%{max_throughput: "5", time: "2", period: "seconds"})

    expired =
      execution_attrs("expired", NaiveDateTime.add(now, 2, :second))
      |> Map.put(:expires_at, DateTime.add(now_utc, -1, :second))

    assert {3, nil} = Repo.insert_all(ActionExecution, [old, latest, expired])

    assert {:ok, config} = ActionQueries.latest_queue_config("queue:claim:test:0")
    assert %{max_throughput: "5", time: "2", period: "seconds"} = config

    assert {1, nil} = ActionQueries.expire_overdue_actions()

    expired_row = Repo.get_by!(ActionExecution, callback_id: "expired")
    assert expired_row.permanently_failed
    assert expired_row.last_failure_reason == "hubspot_block_expired"
  end

  defp execution_attrs(callback_id, inserted_at) do
    %{
      queue_id: "queue:claim:test:0",
      callback_id: callback_id,
      processed: false,
      max_throughput: "1",
      time: "1",
      period: "seconds",
      last_failure_reason: nil,
      consecutive_failures: 0,
      on_hold_until: nil,
      total_attempts: 0,
      permanently_failed: false,
      inserted_at: inserted_at,
      updated_at: inserted_at
    }
  end
end
