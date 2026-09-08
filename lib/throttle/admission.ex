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

            {count, inserted} =
              Repo.insert_all(ActionExecution, [row],
                on_conflict: :nothing,
                conflict_target: [:callback_id],
                returning: true
              )

            action =
              if count == 1 do
                ensure_queue(attrs.queue_id, portal_id, rate)
                hd(inserted)
              else
                Repo.one!(from a in ActionExecution, where: a.callback_id == ^attrs.callback_id)
              end

            # A callback cannot be moved to another queue by a replayed payload.
            if action.queue_id != attrs.queue_id, do: Repo.rollback(:callback_conflict)
            action
          end,
          timeout: 5_000
        )

      case result do
        {:ok, action} -> {:ok, action}
        {:error, :rollback} -> {:error, :unavailable}
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

  defp ensure_queue(queue_id, portal_id, rate) do
    # Most arrivals share an existing rate. Read persisted configuration without
    # locking the dispatcher's queue row; only a changed/missing rate needs a write.
    # Concurrent rate changes may linearize on either side of this read. Replays
    # never reach this path, and no schedule or existing reservation is reset.
    current =
      Repo.query!(
        "SELECT max_throughput, interval_ms FROM dispatch_queues WHERE queue_id=$1",
        [queue_id]
      ).rows

    if current != [[rate.max_throughput, rate.interval_ms]] do
      Repo.query!(
        "INSERT INTO dispatch_portals (portal_id) VALUES ($1) ON CONFLICT DO NOTHING",
        [portal_id]
      )

      Repo.query!(
        """
        INSERT INTO dispatch_queues (queue_id, portal_id, max_throughput, interval_ms, next_run_at)
        VALUES ($1, $2, $3, $4, timezone('UTC', clock_timestamp()))
        ON CONFLICT (queue_id) DO UPDATE SET max_throughput = EXCLUDED.max_throughput,
          interval_ms = EXCLUDED.interval_ms
        WHERE (dispatch_queues.max_throughput, dispatch_queues.interval_ms)
          IS DISTINCT FROM (EXCLUDED.max_throughput, EXCLUDED.interval_ms)
        """,
        [queue_id, portal_id, rate.max_throughput, rate.interval_ms]
      )
    end
  end
end
