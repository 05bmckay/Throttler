defmodule ThrottleWeb.CacheBodyReader do
  @moduledoc """
  Custom body reader that caches the raw request body in `conn.assigns[:raw_body]`.

  Used by `Plug.Parsers` so that downstream plugs (e.g. HubSpot signature
  verification) can access the exact bytes that were sent.
  """

  @doc """
  Reads the request body and caches it in `conn.assigns[:raw_body]`.

  Conforms to the `Plug.Parsers` `:body_reader` callback signature:
  `{module, function, args}` where the function receives `(conn, opts)`.
  """
  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        existing = conn.assigns[:raw_body] || ""
        conn = Plug.Conn.assign(conn, :raw_body, existing <> body)
        {:ok, body, conn}

      {:more, partial, conn} ->
        existing = conn.assigns[:raw_body] || ""
        conn = Plug.Conn.assign(conn, :raw_body, existing <> partial)
        {:more, partial, conn}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
