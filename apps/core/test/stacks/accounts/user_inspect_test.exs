defmodule Stacks.Accounts.UserInspectTest do
  @moduledoc """
  The generated `Stacks.Accounts.User` schema carries `@derive {Inspect, except:
  [...]}` (emitted by the proto codegen from `derive_inspect_except` in
  proto/persisted.exs), so inspecting a user omits its credentials, one-time auth
  tokens and contact PII. This closes the path by which a worker that raised with
  a `%User{}` argument wrote the Argon2 hash and email into a log and
  `oban_jobs.errors`. If a future regeneration drops the redaction, the secrets
  reappear in the output below and this reds.
  """
  use ExUnit.Case, async: true

  alias Stacks.Accounts.User

  test "inspecting a user omits credentials, one-time auth tokens and contact PII" do
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

    assert out =~ "Jane Reader", "non-sensitive fields stay visible for debugging"
    assert out =~ "Stacks.Accounts.User"
  end
end
