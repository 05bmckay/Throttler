defmodule Throttle.Repo.Migrations.AddTokenResponseToOauthTokens do
  use Ecto.Migration

  def change do
    alter table(:oauth_tokens) do
      add :token_response, :map
    end
  end
end
