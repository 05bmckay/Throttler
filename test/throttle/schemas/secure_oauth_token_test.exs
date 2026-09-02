defmodule Throttle.Schemas.SecureOAuthTokenTest do
  use ExUnit.Case, async: true

  alias Throttle.Schemas.SecureOAuthToken

  test "changeset encrypts newly issued OAuth tokens before persistence" do
    access_token = "test-access-token"
    refresh_token = "test-refresh-token"

    changeset =
      SecureOAuthToken.changeset(%SecureOAuthToken{}, %{
        portal_id: 123,
        access_token: access_token,
        refresh_token: refresh_token,
        expires_at: DateTime.utc_now()
      })

    encrypted_access = Ecto.Changeset.get_change(changeset, :access_token)
    encrypted_refresh = Ecto.Changeset.get_change(changeset, :refresh_token)

    refute encrypted_access == access_token
    refute encrypted_refresh == refresh_token
    assert {:ok, ^access_token} = Throttle.Encryption.decrypt(encrypted_access)
    assert {:ok, ^refresh_token} = Throttle.Encryption.decrypt(encrypted_refresh)
  end

  test "invalid changesets do not try to encrypt missing tokens" do
    changeset = SecureOAuthToken.changeset(%SecureOAuthToken{}, %{portal_id: 123})

    refute changeset.valid?
    assert is_nil(Ecto.Changeset.get_change(changeset, :access_token))
    assert is_nil(Ecto.Changeset.get_change(changeset, :refresh_token))
  end
end
