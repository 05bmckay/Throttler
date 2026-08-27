defmodule Throttle.Repo.Migrations.AddEmailToOAuthTokens do
  use Ecto.Migration

  def change do
    alter table(:oauth_tokens) do
      add_if_not_exists(:email, :string)
    end
  end
end
