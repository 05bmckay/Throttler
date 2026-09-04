defmodule Throttle do
  @moduledoc """
  Throttle keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  alias Throttle.{Repo, OAuthManager, QueueManager, Admission}
  alias Throttle.Schemas.ThrottleConfig
  require Logger

  @doc """
  Retrieves the persisted throttle configuration.
  Returns `{:ok, config}` or `{:error, :not_found}`.
  """
  def get_throttle_config(portal_id, action_id) do
    case Repo.get_by(ThrottleConfig, portal_id: portal_id, action_id: action_id) do
      nil -> {:error, :not_found}
      config -> {:ok, config}
    end
  end

  @doc """
  Creates or updates a throttle configuration.
  """
  def upsert_throttle_config(attrs) do
    changeset = ThrottleConfig.changeset(%ThrottleConfig{}, attrs)

    with {:ok, config} <- Ecto.Changeset.apply_action(changeset, :insert),
         {:ok, rate} <-
           Throttle.Rate.parse(config.max_throughput, config.time_period, config.time_unit) do
      Repo.transaction(fn ->
        {:ok, stored} =
          Repo.insert(changeset,
            on_conflict: {:replace, [:max_throughput, :time_period, :time_unit, :updated_at]},
            conflict_target: [:portal_id, :action_id],
            returning: true
          )

        Repo.query!(
          """
          UPDATE dispatch_queues SET max_throughput=$3, interval_ms=$4
          WHERE portal_id=$1 AND split_part(queue_id, ':', 4)=$2
          """,
          [config.portal_id, config.action_id, rate.max_throughput, rate.interval_ms]
        )

        stored
      end)
    else
      {:error, :invalid_rate} ->
        {:error,
         Ecto.Changeset.add_error(changeset, :max_throughput, "invalid or excessive rate")}

      error ->
        error
    end
  end

  @doc """
  Retrieves an OAuth token for a given portal ID.
  """
  def get_oauth_token(portal_id) do
    OAuthManager.get_token(portal_id)
  end

  def create_action_execution(attrs) do
    Admission.admit(attrs)
  end

  @doc """
  Creates a queue identifier from HubSpot parameters.
  """
  def create_queue_identifier(params) do
    QueueManager.create_queue_identifier(params)
  end
end
