defmodule Throttle.RedisManager do
  @moduledoc """
  The RedisManager module handles interactions with Redis for queue management.
  """

  def queue_exists?(redis, queue_id) do
    case Redix.pipeline(redis, [
           ["EXISTS", queue_id],
           ["EXPIRE", queue_id, 14400]
         ]) do
      {:ok, [1, expire_result]} ->
        case expire_result do
          # Key exists and EXPIRE was set successfully
          1 ->
            true

          0 ->
            IO.puts("Key exists but EXPIRE could not be set for queue_id: #{queue_id}")
            true
        end

      # Key doesn't exist
      {:ok, [0, _]} ->
        false

      {:error, error} ->
        IO.puts(
          "Error checking EXISTS or setting EXPIRE for queue_id: #{queue_id}. Error: #{inspect(error)}"
        )

        false
    end
  end

  def add_queue(redis, queue_id, max_throughput, time, period) do
    current_time = System.system_time(:second)

    Redix.pipeline(redis, [
      [
        "HMSET",
        queue_id,
        "max_throughput",
        max_throughput,
        "time",
        time,
        "period",
        period,
        "last_event",
        current_time
      ],
      # 4 hours in seconds
      ["EXPIRE", queue_id, 14400]
    ])
  end

  def get_queue_info(redis, queue_id) do
    case Redix.command(redis, ["HGETALL", queue_id]) do
      {:ok, values} ->
        {:ok, Enum.chunk_every(values, 2) |> Enum.into(%{}, fn [k, v] -> {k, v} end)}

      {:error, error} ->
        {:error, "Failed to get queue info: #{inspect(error)}"}
    end
  end

  def update_last_event(redis, queue_id) do
    current_time = System.system_time(:second)

    Redix.pipeline(redis, [
      ["HSET", queue_id, "last_event", current_time],
      # Reset expiration to 4 hours
      ["EXPIRE", queue_id, 14400]
    ])
  end

  def delete_queue(redis, queue_id) do
    Redix.command(redis, ["DEL", queue_id])
  end
end
