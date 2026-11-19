defmodule Throttle.Delivery do
  @moduledoc "One bounded delivery attempt; durable retry scheduling belongs to DispatchStore."
  alias Throttle.{DispatchStore, HubSpotClient, OAuthManager}

  @auth_retry_reasons [
    :token_not_found,
    :token_refresh_failed,
    :token_refresh_unavailable,
    :token_update_failed,
    :decryption_failed,
    :unauthorized
  ]

  def run(batch) do
    {result, sent_count} =
      case OAuthManager.get_token(batch.portal_id) do
        {:ok, token} ->
          case send_owned(batch, token.access_token) do
            {{:error, :unauthorized}, count} ->
              case OAuthManager.force_refresh_token(batch.portal_id, token.access_token) do
                {:ok, refreshed} -> send_owned(batch, refreshed.access_token)
                error -> {error, count}
              end

            other ->
              other
          end

        error ->
          {error, length(batch.actions)}
      end

    normalized = normalize(result, sent_count)

    finalized =
      case DispatchStore.finish(batch, normalized) do
        {:ok, _} -> normalized
        {:error, :stale_claim} -> {:retry, "stale_claim"}
      end

    :telemetry.execute([:throttle, :delivery, :attempt], %{count: length(batch.actions)}, %{
      result: elem_or_self(finalized)
    })

    finalized
  end

  defp send_owned(batch, token) do
    case DispatchStore.owned_actions(batch) do
      [] -> {{:error, :stale_claim}, 0}
      actions -> {HubSpotClient.send_batch_complete(actions, token), length(actions)}
    end
  end

  defp normalize(:ok, _), do: :ok
  defp normalize({:error, {:rate_limited, seconds}}, _), do: {:rate_limited, seconds}

  defp normalize({:error, {:api_error, status}}, count) when status in [400, 404, 410, 422] do
    if count <= 1,
      do: {:permanent, "callback_http_#{status}"},
      else: {:isolate, "callback_http_#{status}"}
  end

  defp normalize({:error, {:api_error, status}}, _), do: {:retry, "callback_http_#{status}"}

  defp normalize({:error, {:http_error, status}}, _) when is_integer(status),
    do: {:retry, "callback_http_#{status}"}

  defp normalize({:error, reason}, _) when reason in @auth_retry_reasons,
    do: {:auth_retry, Atom.to_string(reason)}

  defp normalize({:error, reason}, _) when is_atom(reason), do: {:retry, Atom.to_string(reason)}
  defp normalize(_, _), do: {:retry, "callback_transport_error"}
  defp elem_or_self(tuple) when is_tuple(tuple), do: elem(tuple, 0)
  defp elem_or_self(atom), do: atom
end
