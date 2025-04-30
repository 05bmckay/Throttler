defmodule ThrottleWeb.ThrottleConfigController do
  use ThrottleWeb, :controller

  alias Throttle

  def create(conn, params) do
    case Throttle.upsert_throttle_config(params) do
      {:ok, config} ->
        conn
        |> put_status(:created)
        |> render("show.json", config: config)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render("error.json", changeset: changeset)
    end
  end

  def show(conn, %{"portal_id" => portal_id, "action_id" => action_id}) do
    # Convert string IDs to integers if necessary, assuming portal_id is integer
    # Add error handling if conversion fails
    portal_id_int = String.to_integer(portal_id)

    case Throttle.get_throttle_config(portal_id_int, action_id) do
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Configuration not found"})

      {:ok, config} ->
        render(conn, "show.json", config: config)
    end
  end
end
