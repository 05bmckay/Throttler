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

  test "initial and refreshed metadata never retain credentials or unknown nested data" do
    metadata = %{
      "hub_id" => 123,
      "scopes" => ["automation"],
      "access_token" => "fake-access",
      "refresh_token" => "fake-refresh",
      "extra" => %{"secret" => "fake"},
      "user" => %{"token" => "fake"}
    }

    attrs = %{
      portal_id: 123,
      access_token: "fake-access",
      refresh_token: "fake-refresh",
      expires_at: DateTime.utc_now(),
      token_response: metadata
    }

    for changeset <- [
          SecureOAuthToken.changeset(%SecureOAuthToken{}, attrs),
          SecureOAuthToken.update_changeset(%SecureOAuthToken{}, attrs)
        ] do
      assert Ecto.Changeset.get_change(changeset, :token_response) ==
               %{"hub_id" => 123, "scopes" => ["automation"]}
    end
  end
end
