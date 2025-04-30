defmodule Throttle do
  @moduledoc """
  Throttle keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  import Ecto.Query
  alias Throttle.{Repo, OAuthManager, QueueManager, ActionBatcher, ConfigCache}
  alias Throttle.Schemas.{ActionExecution, ThrottleConfig}
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


  # def get_next_action_batch(queue_id, limit) do
  #    Throttle.ThrottleWorker.get_next_action_batch(queue_id, limit)
  #  end

    def mark_actions_processed(action_ids) do
      result = from(a in ActionExecution, where: a.id in ^action_ids)
      |> Repo.update_all(set: [processed: true])
      result
    end

  @doc """
  Creates a queue identifier from HubSpot parameters.
  """
  def create_queue_identifier(params) do
    QueueManager.create_queue_identifier(params)
  end
end
