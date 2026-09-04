defmodule Throttle.HTTPStub do
  # Test-only adapter: a missing response crashes rather than contacting HubSpot.
  def request(request, _finch, _opts) do
    Agent.get_and_update(__MODULE__, fn %{responses: [response | rest], requests: requests} ->
      {response, %{responses: rest, requests: [request | requests]}}
    end)
  end

  def start_link(responses),
    do: Agent.start_link(fn -> %{responses: responses, requests: []} end, name: __MODULE__)

  def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))

  def response(status, body \\ "", headers \\ []),
    do: {:ok, %Finch.Response{status: status, body: body, headers: headers}}
end
