[
  inputs: [
    "mix.exs",
    ".formatter.exs",
    "config/**/*.{ex,exs}",
    "lib/**/*.{ex,exs}",
    "test/**/*.{ex,exs}",
    "priv/repo/migrations/*.exs"
  ],
  import_deps: [:ecto, :ecto_sql, :phoenix]
]
