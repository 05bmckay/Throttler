defmodule Throttle.Repo.Migrations.WidenHubspotIdentifiers do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    alter table(:oauth_tokens), do: modify(:portal_id, :bigint)

    alter table(:throttle_configs) do
      modify(:portal_id, :bigint)
    end
  end

  def down do
    raise "Do not narrow HubSpot identifiers; use the paused forward-fix procedure."
  end
end
