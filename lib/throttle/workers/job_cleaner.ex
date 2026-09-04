defmodule Throttle.Workers.JobCleaner do
  @moduledoc "Terminalizes expired actions; durable scheduling needs no runner recovery."
  use Oban.Worker, queue: :maintenance, max_attempts: 3
  require Logger

  def perform(%Oban.Job{}) do
    {count, _} = Throttle.DispatchStore.expire()
    if count > 0, do: Logger.warning("Expired #{count} undelivered HubSpot callbacks")
    :ok
  end
end
