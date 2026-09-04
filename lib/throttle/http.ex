defmodule Throttle.HTTP do
  @moduledoc "Bounded HubSpot HTTP transport; injectable for failure and concurrency tests."
  def request(request) do
    adapter = Application.get_env(:throttle, :http_adapter, Finch)
    adapter.request(request, Throttle.Finch, receive_timeout: 15_000, request_timeout: 30_000)
  end
end
