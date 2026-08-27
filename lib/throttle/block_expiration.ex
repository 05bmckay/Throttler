defmodule Throttle.BlockExpiration do
  @moduledoc """
  Converts the configured HubSpot BLOCK duration into a persisted deadline.

  HubSpot expects an ISO 8601 duration. The throttler intentionally accepts the
  fixed-length units it can convert without calendar ambiguity: weeks, days,
  hours, minutes, and seconds.
  """

  @duration_pattern ~r/\AP(?:(?<weeks>\d+)W)?(?:(?<days>\d+)D)?(?:T(?:(?<hours>\d+)H)?(?:(?<minutes>\d+)M)?(?:(?<seconds>\d+)S)?)?\z/

  def configured_duration do
    Application.fetch_env!(:throttle, :hubspot_block_expiration_duration)
  end

  def configured_seconds! do
    configured_duration()
    |> seconds()
    |> case do
      {:ok, seconds} -> seconds
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  def expires_at(now \\ DateTime.utc_now()) do
    now
    |> DateTime.add(configured_seconds!(), :second)
    |> DateTime.truncate(:second)
  end

  def seconds(duration) when is_binary(duration) do
    case Regex.named_captures(@duration_pattern, duration) do
      %{
        "weeks" => weeks,
        "days" => days,
        "hours" => hours,
        "minutes" => minutes,
        "seconds" => seconds
      } ->
        total =
          integer(weeks) * 7 * 86_400 +
            integer(days) * 86_400 +
            integer(hours) * 3_600 +
            integer(minutes) * 60 +
            integer(seconds)

        if total > 0 do
          {:ok, total}
        else
          {:error, "HubSpot BLOCK expiration duration must be greater than zero"}
        end

      _ ->
        {:error,
         "invalid HubSpot BLOCK expiration duration #{inspect(duration)}; expected fixed-length ISO 8601 units such as P2W or P1WT1H"}
    end
  end

  def seconds(duration) do
    {:error, "invalid HubSpot BLOCK expiration duration #{inspect(duration)}"}
  end

  defp integer(""), do: 0
  defp integer(nil), do: 0
  defp integer(value), do: String.to_integer(value)
end
