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
    case Throttle.get_throttle_config(portal_id, action_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Configuration not found"})

      config ->
        render(conn, "show.json", config: config)
    end
  end
end
