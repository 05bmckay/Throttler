defmodule Throttle.Repo.Migrations.SanitizeOauthMetadata do
  use Ecto.Migration

  def up do
    # Keep only non-secret identity metadata. Never copy secret values into logs,
    # audit tables, or rollback scripts.
    execute("""
    UPDATE oauth_tokens SET token_response = (
      SELECT COALESCE(jsonb_object_agg(key, value), '{}'::jsonb)
      FROM jsonb_each(CASE WHEN jsonb_typeof(token_response) = 'object'
                          THEN token_response ELSE '{}'::jsonb END)
      WHERE key IN ('hub_id', 'hub_domain', 'user', 'user_id', 'app_id', 'scopes', 'token_type')
    ) WHERE token_response IS NOT NULL
    """)
  end

  def down, do: :ok
end
