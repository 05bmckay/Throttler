defmodule Throttle.Schemas.SecureOAuthToken do
  use Ecto.Schema
  import Ecto.Changeset
  require Logger

  schema "oauth_tokens" do
    field(:portal_id, :integer)
    field(:access_token, :string)
    field(:refresh_token, :string)
    field(:expires_at, :utc_datetime)
    field(:token_response, :map)
    field(:email, :string)

    timestamps()
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [
      :portal_id,
      :access_token,
      :refresh_token,
      :expires_at,
      :token_response,
      :email
    ])
    |> validate_required([:portal_id, :access_token, :refresh_token, :expires_at])
    |> unique_constraint(:portal_id)
  end

  def update_changeset(token, attrs) do
    token
    |> cast(attrs, [:access_token, :refresh_token, :expires_at, :token_response, :email])
    |> validate_required([:access_token, :refresh_token, :expires_at])
  end

  def decrypt_tokens(token) do
    with {:ok, access} <- Throttle.Encryption.decrypt(token.access_token),
         {:ok, refresh} <- Throttle.Encryption.decrypt(token.refresh_token) do
      {:ok, %{token | access_token: access, refresh_token: refresh}}
    else
      {:error, reason} ->
        Logger.error("Failed to decrypt tokens for portal #{token.portal_id}: #{inspect(reason)}")
        {:error, :decryption_failed}
    end
  end
end
