defmodule Throttle.Repo.Migrations.CreateOAuthTokens do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:oauth_tokens) do
      add(:portal_id, :integer)
      add(:access_token, :text)
      add(:refresh_token, :text)
      add(:expires_at, :utc_datetime)
      add(:token_response, :map)
      add(:email, :string)

      timestamps()
    end
  end
end
