defmodule Throttle.LogRedactor do
  @moduledoc """
  Redacts credentials from Logger events, including structured OTP crash reports.
  """

  @filter_id :throttle_secret_redaction
  @redacted "[REDACTED]"
  @sensitive_keys MapSet.new([
                    :access_token,
                    :authorization,
                    :client_secret,
                    :database_url,
                    :encryption_key,
                    :password,
                    :refresh_token,
                    :secret,
                    :secret_key_base,
                    :token,
                    "access_token",
                    "authorization",
                    "client_secret",
                    "database_url",
                    "encryption_key",
                    "password",
                    "refresh_token",
                    "secret",
                    "secret_key_base",
                    "token"
                  ])

  def install do
    case :logger.add_primary_filter(@filter_id, {&__MODULE__.filter/2, []}) do
      :ok -> :ok
      {:error, {:already_exist, @filter_id}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def filter(%{} = event, _extra) do
    redact(event)
  rescue
    _error -> :stop
  catch
    _kind, _reason -> :stop
  end

  def filter(event, _extra), do: event

  def redact(%{} = map) do
    Map.new(map, fn {key, value} ->
      {key, if(sensitive_key?(key), do: @redacted, else: redact(value))}
    end)
  end

  def redact([]), do: []
  def redact([head | tail]), do: [redact(head) | redact(tail)]

  def redact({key, value}) do
    {key, if(sensitive_key?(key), do: @redacted, else: redact(value))}
  end

  def redact(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&redact/1)
    |> List.to_tuple()
  end

  def redact(value) when is_binary(value) do
    if String.valid?(value) do
      value =
        Regex.replace(
          ~r/(?i)(postgres(?:ql)?:\/\/[^:\s]+:)[^@\s]+(@)/,
          value,
          "\\1#{@redacted}\\2"
        )

      value =
        Regex.replace(
          ~r/(?i)(authorization:\s*bearer\s+)[^\s,]+/,
          value,
          "\\1#{@redacted}"
        )

      Regex.replace(
        ~r/(?i)((?:access_token|refresh_token|client_secret|encryption_key|secret_key_base|database_url|authorization|password|token)\s*[\"']?\s*(?::|=>)\s*[\"']?)[^\"'\s,}\]]+/,
        value,
        "\\1#{@redacted}"
      )
    else
      value
    end
  end

  def redact(value), do: value

  defp sensitive_key?(key), do: MapSet.member?(@sensitive_keys, key)
end
