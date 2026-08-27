defmodule Throttle.StartupRecovery do
  @moduledoc """
  Performs one bounded backlog recovery pass when the application starts.

  The normal Oban cron remains the long-running safety net. This task closes
  the five-minute blind spot after a deploy or instance restart.
  """

  use Task
  require Logger

  def start_link(_opts) do
    Task.start_link(__MODULE__, :run, [])
  end

  def run do
    limit = Application.get_env(:throttle, :startup_recovery_queues, 4)

    recover(limit)
  end

  defp recover(limit) when limit <= 0, do: :ok

  defp recover(limit) do
    case Throttle.Workers.JobCleaner.recover_missing_queues(limit) do
      :ok -> :ok
      {:error, reason} -> Logger.error("Startup backlog recovery failed: #{inspect(reason)}")
    end
  end
end
