defmodule Throttle.Schemas.SecureOAuthToken do
  @moduledoc """
  Schema for securely storing OAuth tokens. This uses encryption
  to protect sensitive token data.
  """

  use Ecto.Schema
  import Ecto.Changeset
  alias Throttle.Encryption

  schema "oauth_tokens" do
    field(:portal_id, :integer)
    field(:access_token, :string)
    field(:refresh_token, :string)
    field(:expires_at, :utc_datetime)

    timestamps()
  end

  @doc """
  Changeset function for SecureOAuthToken. This function also handles
  encryption of sensitive fields.
  """
  def changeset(token, attrs) do
    token
    |> cast(attrs, [:portal_id, :access_token, :refresh_token, :expires_at])
    |> validate_required([:portal_id, :access_token, :refresh_token, :expires_at])
    |> unique_constraint(:portal_id)
    |> encrypt_tokens()
  end

  @doc """
  Decrypts the tokens in a SecureOAuthToken struct.
  """
  def decrypt_tokens(token) do
    %{
      token
      | access_token: Encryption.decrypt(token.access_token),
        refresh_token: Encryption.decrypt(token.refresh_token)
    }
  end

  defp encrypt_tokens(changeset) do
    case changeset do
      %Ecto.Changeset{valid?: true, changes: changes} ->
        changes =
          changes
          |> maybe_encrypt_field(:access_token)
          |> maybe_encrypt_field(:refresh_token)

        %{changeset | changes: changes}

      _ ->
        changeset
    end
  end

  defp maybe_encrypt_field(changes, field) do
    case Map.get(changes, field) do
      nil -> changes
      value -> Map.put(changes, field, Encryption.encrypt(value))
    end
  end
end
