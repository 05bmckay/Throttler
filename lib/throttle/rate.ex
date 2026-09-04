defmodule Throttle.Rate do
  @moduledoc "Validated rates shared by webhook admission and queue scheduling."
  @units %{
    "second" => 1_000,
    "seconds" => 1_000,
    "minute" => 60_000,
    "minutes" => 60_000,
    "hour" => 3_600_000,
    "hours" => 3_600_000,
    "day" => 86_400_000,
    "days" => 86_400_000
  }

  def parse(throughput, time, period) do
    with {:ok, count} <- positive(throughput),
         {:ok, time} <- positive(time),
         unit when is_integer(unit) <- Map.get(@units, period),
         true <- count <= 10_000 and time * unit <= 2_419_200_000 do
      {:ok, %{max_throughput: count, interval_ms: time * unit}}
    else
      _ -> {:error, :invalid_rate}
    end
  end

  def positive(value) when is_integer(value) and value > 0, do: {:ok, value}

  def positive(value) when is_binary(value) do
    case Integer.parse(value) do
      {value, ""} when value > 0 -> {:ok, value}
      _ -> {:error, :invalid_integer}
    end
  end

  def positive(_), do: {:error, :invalid_integer}
end
