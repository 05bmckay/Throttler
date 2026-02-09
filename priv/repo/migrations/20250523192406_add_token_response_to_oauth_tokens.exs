defmodule Throttle.Repo.Migrations.AddTokenResponseToOauthTokens do
  use Ecto.Migration

  def change do
    alter table(:oauth_tokens) do
      add_if_not_exists(:token_response, :map)
    end
  end
end
