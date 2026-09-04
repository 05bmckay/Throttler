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
    |> sanitize_metadata()
    |> encrypt_tokens()
  end

  def update_changeset(token, attrs) do
    token
    |> cast(attrs, [:access_token, :refresh_token, :expires_at, :token_response, :email])
    |> validate_required([:access_token, :refresh_token, :expires_at])
    |> sanitize_metadata()
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

  @metadata_keys ~w(hub_id hub_domain user user_id app_id scopes token_type)

  defp sanitize_metadata(changeset) do
    update_change(changeset, :token_response, fn metadata ->
      metadata
      |> Map.take(@metadata_keys)
      |> Map.filter(fn {_key, value} ->
        is_binary(value) or is_number(value) or is_nil(value) or
          (is_list(value) and Enum.all?(value, &is_binary/1))
      end)
    end)
  end

  defp encrypt_tokens(%Ecto.Changeset{valid?: true} = changeset) do
    changeset
    |> update_change(:access_token, &Throttle.Encryption.encrypt/1)
    |> update_change(:refresh_token, &Throttle.Encryption.encrypt/1)
  end

  defp encrypt_tokens(changeset), do: changeset
end
