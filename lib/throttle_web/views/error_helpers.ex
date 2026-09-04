defmodule ThrottleWeb.ErrorHelpers do
  @moduledoc "Translate validation errors for the JSON API."
  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(ThrottleWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(ThrottleWeb.Gettext, "errors", msg, opts)
    end
  end
end
