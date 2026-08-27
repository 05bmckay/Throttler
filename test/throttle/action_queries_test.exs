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
end
