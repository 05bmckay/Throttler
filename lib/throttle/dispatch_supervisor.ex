defmodule Throttle.DispatchSupervisor do
  @moduledoc "Restarting the scheduler also stops its in-flight tasks before replacement."
  use Supervisor
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts) do
    Supervisor.init(
      [
        {Task.Supervisor, name: Throttle.DeliverySupervisor, max_children: 16},
        Throttle.Dispatcher
      ],
      strategy: :one_for_all
    )
  end
end
