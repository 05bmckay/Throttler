# HISTORICAL BASELINE PROBES for commit 1838519. These intentionally characterize
# old bugs and reference the old architecture; use test/ for candidate validation.
# Audit characterization probes: assertions confirm current undesirable behavior.
# These are evidence, not acceptance tests for the proposed replacement.
# Run: mix test docs/audits/2026-09-04/audit_probe_test.exs

defmodule Throttle.AuditProbesTest do
  use Throttle.DataCase
  alias Throttle.{ActionBatcher, ActionQueries, Repo, QueueRunner}
  alias Throttle.Schemas.ActionExecution

  defp attrs(callback) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    %{
      queue_id: "queue:901:902:903:0",
      callback_id: callback,
      processed: false,
      permanently_failed: false,
      max_throughput: "1",
      time: "1",
      period: "days",
      inserted_at: now,
      updated_at: now
    }
  end

  test "admission returns success before any durable action exists" do
    {:ok, state} = ActionBatcher.init(%{})
    Process.cancel_timer(state.timer_ref)
    deadline = System.monotonic_time(:millisecond) + 1_000

    assert {:reply, :ok, accepted} =
             ActionBatcher.handle_call(
               {:add_action, attrs("accepted-only-in-memory"), deadline},
               {self(), make_ref()},
               state
             )

    assert accepted.buffer_size == 1
    assert Repo.get_by(ActionExecution, callback_id: "accepted-only-in-memory") == nil
  end

  test "on_conflict nothing admits and independently leases duplicate callbacks" do
    row = attrs("same-callback")
    assert {2, _} = Repo.insert_all(ActionExecution, [row, row], on_conflict: :nothing)
    assert {:ok, [first]} = ActionQueries.get_next_action_batch(row.queue_id, "1")
    assert {:ok, [second]} = ActionQueries.get_next_action_batch(row.queue_id, "1")
    assert first.id != second.id
    assert first.callback_id == second.callback_id
  end

  test "successful callback can be reinserted and claimed on a later webhook retry" do
    row = attrs("completed-then-replayed")
    Repo.insert_all(ActionExecution, [row])
    ActionQueries.mark_callbacks_processed_and_clear_errors([row.callback_id])
    assert {1, _} = Repo.insert_all(ActionExecution, [row], on_conflict: :nothing)
    assert {:ok, [_]} = ActionQueries.get_next_action_batch(row.queue_id, "1")
  end

  test "stale owner still passes dispatch eligibility after a different claim" do
    row = attrs("reclaimed")
    Repo.insert_all(ActionExecution, [row])
    assert {:ok, [old_claim]} = ActionQueries.get_next_action_batch(row.queue_id, "1")
    expired = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(a in ActionExecution, where: a.id == ^old_claim.id),
      set: [on_hold_until: expired]
    )

    assert {:ok, [new_claim]} = ActionQueries.get_next_action_batch(row.queue_id, "1")
    assert old_claim.id == new_claim.id
    assert MapSet.member?(ActionQueries.processable_action_ids([old_claim.id]), old_claim.id)
  end

  test "two runner initializations both schedule immediate work for a daily limit" do
    config = %{config_id: 1, max_throughput: "1", time: "1", period: "days"}

    for _ <- 1..2 do
      {:ok, state} = QueueRunner.init({"queue:901:902:903:0", config})
      assert state.delay_ms == 86_400_000
      assert_receive {:tick, 1}, 100
      Process.cancel_timer(state.timer_ref)
    end
  end

  test "OAuth metadata retains plaintext copies while the dedicated fields are encrypted" do
    access = "audit-fake-access-token"
    refresh = "audit-fake-refresh-token"

    changeset =
      Throttle.Schemas.SecureOAuthToken.changeset(
        %Throttle.Schemas.SecureOAuthToken{},
        %{
          portal_id: 901,
          access_token: access,
          refresh_token: refresh,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          token_response: %{"access_token" => access, "refresh_token" => refresh}
        }
      )

    assert changeset.valid?
    stored = Ecto.Changeset.apply_changes(changeset)
    refute stored.access_token == access
    refute stored.refresh_token == refresh
    assert stored.token_response["access_token"] == access
    assert stored.token_response["refresh_token"] == refresh
  end

  test "JSON string-keyed config parameters raise instead of creating a config" do
    params = %{
      "portal_id" => 901,
      "action_id" => "903",
      "max_throughput" => 1,
      "time_period" => 1,
      "time_unit" => "seconds"
    }

    assert_raise KeyError, fn -> Throttle.upsert_throttle_config(params) end
  end
end
