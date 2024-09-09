defmodule Throttle.Repo do
  @moduledoc """
  The Ecto Repo for the Throttle application.
  This module is responsible for database interactions.
  """

  use Ecto.Repo,
    otp_app: :throttle,
    adapter: Ecto.Adapters.Postgres
end
