defmodule Throttle.Schemas.ThrottleConfig do
  @moduledoc """
  Schema for storing throttle configurations. This allows for
  dynamic throttle settings that can be adjusted without code changes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "throttle_configs" do
    field(:portal_id, :integer)
    field(:action_id, :string)
    field(:max_throughput, :integer)
    field(:time_period, :integer)
    field(:time_unit, :string)

    timestamps()
  end

  @doc """
  Changeset function for ThrottleConfig.
  """
  def changeset(config, attrs) do
    config
    |> cast(attrs, [:portal_id, :action_id, :max_throughput, :time_period, :time_unit])
    |> validate_required([:portal_id, :action_id, :max_throughput, :time_period, :time_unit])
    |> validate_inclusion(:time_unit, ~w(second minute hour day))
    |> unique_constraint([:portal_id, :action_id])
  end
end
