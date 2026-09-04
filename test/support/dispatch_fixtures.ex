defmodule Throttle.DispatchFixtures do
  def attrs(callback, overrides \\ %{}) do
    Map.merge(
      %{
        queue_id: "queue:901:902:903:0",
        callback_id: callback,
        max_throughput: "2",
        time: "1",
        period: "seconds",
        expires_at: Throttle.BlockExpiration.expires_at()
      },
      overrides
    )
  end

  def admit(callback, overrides \\ %{}) do
    {:ok, action} = Throttle.Admission.admit(attrs(callback, overrides))
    action
  end

  def due(queue_id \\ "queue:901:902:903:0") do
    Throttle.Repo.query!(
      "UPDATE dispatch_queues SET next_run_at=now()-interval '1 second' WHERE queue_id=$1",
      [queue_id]
    )
  end
end
