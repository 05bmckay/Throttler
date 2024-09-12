defmodule Throttle.Schemas.SecureOAuthToken do
  use Ecto.Schema
  import Ecto.Changeset
  require Logger

  schema "oauth_tokens" do
    field :portal_id, :integer
    field :access_token, :string
    field :refresh_token, :string
    field :expires_at, :utc_datetime

    timestamps()
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:portal_id, :access_token, :refresh_token, :expires_at])
    |> validate_required([:portal_id, :access_token, :refresh_token, :expires_at])
    |> unique_constraint(:portal_id)
  end

  def update_changeset(token, attrs) do
    token
    |> cast(attrs, [:access_token, :refresh_token, :expires_at])
    |> validate_required([:access_token, :refresh_token, :expires_at])
  end

  def decrypt_tokens(token) do
    access_token = case Throttle.Encryption.decrypt(token.access_token) do
      {:ok, decrypted} -> decrypted
      {:error, _} ->
        Logger.warning("Failed to decrypt access token for portal #{token.portal_id}")
        token.access_token
    end
    refresh_token = case Throttle.Encryption.decrypt(token.refresh_token) do
      {:ok, decrypted} -> decrypted
      {:error, _} ->
        Logger.warning("Failed to decrypt refresh token for portal #{token.portal_id}")
        token.refresh_token
    end
    %{token | access_token: access_token, refresh_token: refresh_token}
  end

  defp encrypt_tokens(changeset) do
    changeset
    |> update_change(:access_token, &Encryption.encrypt/1)
    |> update_change(:refresh_token, &Encryption.encrypt/1)
  end

  defp maybe_encrypt_field(changes, field) do
    case Map.get(changes, field) do
      nil -> changes
      value -> Map.put(changes, field, Encryption.encrypt(value))
    end
  end
end
