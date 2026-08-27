defmodule Throttle.LogRedactorTest do
  use ExUnit.Case, async: true

  alias Throttle.LogRedactor

  test "redacts credentials inside structured OTP reports" do
    event = %{
      level: :error,
      msg:
        {:report,
         %{
           label: :crash,
           report: [
             initial_call:
               {DBConnection.Connection, :start_link,
                [[username: "root", password: "database-password", token: "oauth-token"]]}
           ]
         }}
    }

    redacted = LogRedactor.filter(event, [])
    inspected = inspect(redacted)

    refute inspected =~ "database-password"
    refute inspected =~ "oauth-token"
    assert inspected =~ "[REDACTED]"
  end

  test "redacts credentials embedded in string messages" do
    message =
      "DATABASE_URL=postgresql://root:database-password@example.com/db password: secret-value"

    redacted = LogRedactor.redact(message)

    refute redacted =~ "database-password"
    refute redacted =~ "secret-value"
    assert redacted =~ "postgresql://root:[REDACTED]@example.com/db"
  end

  test "redacts credential keys embedded in inspected maps and JSON" do
    message =
      ~s(%{"access_token" => "oauth-access", "refresh_token":"oauth-refresh", client_secret: "client-secret"})

    redacted = LogRedactor.redact(message)

    refute redacted =~ "oauth-access"
    refute redacted =~ "oauth-refresh"
    refute redacted =~ "client-secret"
    assert redacted =~ "[REDACTED]"
  end

  test "leaves invalid UTF-8 binaries intact instead of crashing the logger filter" do
    invalid_utf8 = <<255, 254, 0>>

    assert LogRedactor.redact(invalid_utf8) == invalid_utf8
  end

  test "redacts improper lists found in Erlang crash reports" do
    report = [{:password, "database-password"} | :not_a_list]

    assert LogRedactor.redact(report) == [{:password, "[REDACTED]"} | :not_a_list]
  end
end
