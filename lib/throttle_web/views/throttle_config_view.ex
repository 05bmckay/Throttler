defmodule ThrottleWeb.ThrottleConfigView do
  use ThrottleWeb, :view

  def render("show.json", %{config: config}) do
    %{
      portal_id: config.portal_id,
      action_id: config.action_id,
      max_throughput: config.max_throughput,
      time_period: config.time_period,
      time_unit: config.time_unit
    }
  end

  def render("error.json", %{changeset: changeset}) do
    %{errors: translate_errors(changeset)}
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, &translate_error/1)
  end
end
