defmodule ThrottleWeb.ErrorView do
  use ThrottleWeb, :view

  def render("404.json", _assigns), do: %{errors: %{detail: "Not Found"}}

  def render("500.json", _assigns), do: %{errors: %{detail: "Internal Server Error"}}

  def template_not_found(template, assigns) do
    render("500.json", Map.put(assigns, :template, template))
  end
end
