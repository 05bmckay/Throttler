defmodule Throttle.Repo.Migrations.FixTokenResponseColumnType do
  use Ecto.Migration

  @doc """
  The original oauth_tokens table may have created token_response as :string/:text.
  Migration 20250523192406 used add_if_not_exists(:token_response, :map) which is
  a no-op if the column already exists — leaving it as text/varchar while the Ecto
  schema declares :map (jsonb).

  This causes DBConnection.EncodeError when OAuthManager tries to store the HubSpot
  token details map: Postgrex expects a binary for text columns but receives a map.

  Fix: explicitly modify the column to :map (jsonb), casting any existing text values.
  """
  def up do
    execute("""
    ALTER TABLE oauth_tokens
    ALTER COLUMN token_response TYPE jsonb
    USING CASE
      WHEN token_response IS NULL THEN NULL
      ELSE token_response::jsonb
    END
    """)
  end

  def down do
    execute("""
    ALTER TABLE oauth_tokens
    ALTER COLUMN token_response TYPE text
    USING CASE
      WHEN token_response IS NULL THEN NULL
      ELSE token_response::text
    END
    """)
  end
end
