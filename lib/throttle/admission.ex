defmodule Throttle.Admission do
  @moduledoc "Durable callback admission; success is returned only after commit."
  alias Throttle.{Repo, Rate}
  alias Throttle.Schemas.ActionExecution
  import Ecto.Query

  def admit(attrs) do
    if Application.get_env(:throttle, :admission_enabled, true),
      do: persist(attrs),
      else: {:error, :unavailable}
  end

  defp persist(attrs) do
    with {:ok, rate} <- Rate.parse(attrs.max_throughput, attrs.time, attrs.period),
         ["queue", portal, _, _, _] <- String.split(attrs.queue_id, ":"),
         {:ok, portal_id} <- Rate.positive(portal),
         true <- portal_id <= 9_223_372_036_854_775_807,
         true <- is_binary(attrs.callback_id) and byte_size(attrs.callback_id) in 1..255 do
      now = DateTime.utc_now()

      result =
        Repo.transaction(
          fn ->
            # The callback unique index arbitrates concurrent retries. Insert first;
            # a duplicate must never overwrite the current queue's configuration.
            row =
              Map.take(attrs, [
                :queue_id,
                :callback_id,
                :max_throughput,
                :time,
                :period,
                :expires_at
              ])
              |> Map.merge(%{
                processed: false,
                inserted_at: DateTime.to_naive(now) |> NaiveDateTime.truncate(:second),
                updated_at: DateTime.to_naive(now) |> NaiveDateTime.truncate(:second)
              })

            {count, _} =
              Repo.insert_all(ActionExecution, [row],
                on_conflict: :nothing,
                conflict_target: [:callback_id]
              )

            if count == 1 do
              Repo.query!(
                "INSERT INTO dispatch_portals (portal_id) VALUES ($1) ON CONFLICT DO NOTHING",
                [portal_id]
              )

              Repo.query!(
                """
                INSERT INTO dispatch_queues (queue_id, portal_id, max_throughput, interval_ms, next_run_at)
                VALUES ($1, $2, $3, $4, $5)
                ON CONFLICT (queue_id) DO UPDATE SET max_throughput = EXCLUDED.max_throughput,
                  interval_ms = EXCLUDED.interval_ms
                """,
                [attrs.queue_id, portal_id, rate.max_throughput, rate.interval_ms, now]
              )
            end

            action =
              Repo.one!(from a in ActionExecution, where: a.callback_id == ^attrs.callback_id)

            # A callback cannot be moved to another queue by a replayed payload.
            if action.queue_id != attrs.queue_id, do: Repo.rollback(:callback_conflict)
            action
          end,
          timeout: 5_000
        )

      case result do
        {:ok, action} -> {:ok, action}
        {:error, reason} -> {:error, reason}
      end
    else
      _ -> {:error, :invalid_action}
    end
  rescue
    _e in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end
end
