defmodule ThrottleWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint ThrottleWeb.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import ThrottleWeb.ConnCase
      alias ThrottleWeb.Router.Helpers, as: Routes
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Throttle.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
