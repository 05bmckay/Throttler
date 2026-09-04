defmodule Throttle.ActionBatcherTest do
  # The buffer and mailbox deadlines have been removed. Preserve the admission
  # regression at its new boundary: no successful response before persistence.
  use Throttle.DataCase
  import Throttle.DispatchFixtures

  test "admission has no in-memory success or later ghost insert" do
    assert {:error, :invalid_action} =
             Throttle.Admission.admit(attrs("invalid", %{max_throughput: "0"}))

    assert Throttle.Repo.aggregate(Throttle.Schemas.ActionExecution, :count) == 0
    action = admit("committed")

    assert Throttle.Repo.get!(Throttle.Schemas.ActionExecution, action.id).callback_id ==
             "committed"

    assert Process.whereis(Throttle.ActionBatcher) == nil
  end
end
