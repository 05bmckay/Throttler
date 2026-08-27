defmodule ThrottleWeb.ErrorViewTest do
  use ExUnit.Case, async: true

  alias ThrottleWeb.ErrorView

  test "renders scanner 404s without raising another exception" do
    assert %{errors: %{detail: "Not Found"}} = ErrorView.render("404.json", %{})
  end

  test "uses a safe JSON response for unknown error templates" do
    assert %{errors: %{detail: "Internal Server Error"}} =
             ErrorView.template_not_found("503.json", %{})
  end
end
