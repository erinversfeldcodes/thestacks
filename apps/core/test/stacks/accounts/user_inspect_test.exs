defmodule Stacks.Accounts.UserInspectTest do
  use ExUnit.Case, async: true

  alias Stacks.Accounts.User

  test "inspecting a user redacts credentials, one-time auth tokens and contact PII" do
    user = %User{
      id: "11111111-1111-1111-1111-111111111111",
      email: "person@example.com",
      pending_email: "new@example.com",
      password_hash: "argon2id-v19-secrethash",
      password: "plaintext-secret",
      email_confirmation_token: "confirm-token-xyz",
      password_reset_token: "reset-token-xyz",
      pending_email_token: "pending-token-xyz",
      pending_email_revert_token: "revert-token-xyz",
      display_name: "Jane Reader",
      consent_analytics: true
    }

    out = inspect(user)

    for secret <- [
          "person@example.com",
          "new@example.com",
          "secrethash",
          "plaintext-secret",
          "confirm-token-xyz",
          "reset-token-xyz",
          "pending-token-xyz",
          "revert-token-xyz"
        ] do
      refute out =~ secret, "inspect leaked #{secret}:\n#{out}"
    end

    assert out =~ "**redacted**"
    assert out =~ "Jane Reader", "non-sensitive fields stay visible for debugging"
    assert out =~ "Stacks.Accounts.User"
  end

  test "a nil secret is not rendered as a redaction marker" do
    out = inspect(%User{id: "x", display_name: "Nil Secrets", password_hash: nil})
    assert out =~ "Nil Secrets"
  end
end
