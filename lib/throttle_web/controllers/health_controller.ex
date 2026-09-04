defmodule ThrottleWeb.HealthController do
  use ThrottleWeb, :controller

  def live(conn, _params), do: json(conn, %{status: "alive"})

  def show(conn, _params) do
    with true <- Application.get_env(:throttle, :admission_enabled, true),
         %{enabled: true} <- Throttle.Dispatcher.status(),
         {:ok, %{rows: [[true]]}} <-
           Throttle.Repo.query(
             "SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE version=20260904193000)",
             [],
             timeout: 1_000
           ) do
      json(conn, %{status: "ok"})
    else
      _ -> unavailable(conn)
    end
  rescue
    _ -> unavailable(conn)
  catch
    :exit, _ -> unavailable(conn)
  end

  defp unavailable(conn),
    do: conn |> put_status(:service_unavailable) |> json(%{status: "unavailable"})
end
