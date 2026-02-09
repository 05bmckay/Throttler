defmodule Throttle do
  @moduledoc """
  Throttle keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  alias Throttle.{Repo, OAuthManager, QueueManager, ActionBatcher, ConfigCache}
  alias Throttle.Schemas.ThrottleConfig
  require Logger

  @doc """
  Retrieves a throttle configuration, using the cache first.
  Returns `{:ok, config}` or `{:error, :not_found}`.
  """
  def get_throttle_config(portal_id, action_id) do
    ConfigCache.get_config(portal_id, action_id)
  end

  @doc """
  Creates or updates a throttle configuration.
  """
  def upsert_throttle_config(attrs) do
    result =
      %ThrottleConfig{}
      |> ThrottleConfig.changeset(attrs)
      |> Repo.insert(
        on_conflict: [
          set: [
            max_throughput: attrs.max_throughput,
            time_period: attrs.time_period,
            time_unit: attrs.time_unit
          ]
        ],
        conflict_target: [:portal_id, :action_id]
      )

    case result do
      {:ok, config} ->
        ConfigCache.bust_cache(config.portal_id, config.action_id)
        {:ok, config}

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
    ActionBatcher.add_action(attrs)
  end

  @doc """
  Creates a queue identifier from HubSpot parameters.
  """
  def create_queue_identifier(params) do
    QueueManager.create_queue_identifier(params)
  end
end
