defmodule Stacks.DegradedAccountRecoveryTest do
  use Core.DataCase, async: false

  import Stacks.Factory

  alias Stacks.Accounts

  # A degraded account is what the lapsed-email-change sweep leaves behind:
  # confirmed status withdrawn, pending quartet deliberately kept so the row can
  # still say what it is waiting on and the undo link still resolves.
  defp degraded_user(attrs \\ []) do
    user = insert(:user, Keyword.merge([email_confirmed: true], attrs))

    {:ok, pending} =
      user
      |> Accounts.pending_email_changeset(%{
        pending_email: "new-#{System.unique_integer([:positive])}@example.com",
        pending_email_token: "tok-#{System.unique_integer([:positive])}",
        pending_email_sent_at: DateTime.utc_now() |> DateTime.truncate(:second),
        pending_email_revert_token: "rev-#{System.unique_integer([:positive])}"
      })
      |> Repo.update()

    {:ok, degraded} = Accounts.degrade_lapsed_email_change(pending.id)
    degraded
  end

  describe "list_degraded_accounts/0" do
    test "lists an account degraded by a lapsed email change" do
      degraded = degraded_user()

      assert [found] = Accounts.list_degraded_accounts()
      assert found.id == degraded.id
    end

    test "does NOT list an abandoned signup — the reaper erases those" do
      # Same email_confirmed value, entirely different situation. Confusing the
      # two is a data-loss bug, not a cosmetic one: expired_unverified_ids/1's
      # callers ERASE what it returns.
      insert(:user, email_confirmed: false, pending_email: nil)

      assert Accounts.list_degraded_accounts() == [],
             "an unconfirmed signup with no email change in flight is not degraded"
    end

    test "does NOT list a healthy account with a change still in flight" do
      user = insert(:user, email_confirmed: true)

      {:ok, _} =
        user
        |> Accounts.pending_email_changeset(%{
          pending_email: "later@example.com",
          pending_email_token: "tok",
          pending_email_sent_at: DateTime.utc_now() |> DateTime.truncate(:second),
          pending_email_revert_token: "rev"
        })
        |> Repo.update()

      assert Accounts.list_degraded_accounts() == [],
             "a change in flight on a still-confirmed account has not degraded anything"
    end
  end

  describe "restore_degraded_account/1" do
    test "restores the account to its settled address and clears the pending change" do
      degraded = degraded_user()
      settled = degraded.email

      assert {:ok, restored} = Accounts.restore_degraded_account(degraded.id)

      assert restored.email == settled, "the account keeps the address it answers on"
      assert restored.email_confirmed, "this is what lets the reader back in"
      assert is_nil(restored.pending_email)
      assert is_nil(restored.pending_email_token)
      assert is_nil(restored.pending_email_revert_token)
    end

    test "revokes sessions, carrying across the guarantee the undo link makes" do
      degraded = degraded_user()

      {:ok, _family} =
        Accounts.rotate_token_family(%{
          user_id: degraded.id,
          family_id: Ecto.UUID.generate(),
          current_jti: Ecto.UUID.generate(),
          session_started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      seed_guardian_token(degraded.id)

      assert live_family_count(degraded.id) > 0
      assert guardian_token_count(degraded.id) > 0

      assert {:ok, _restored} = Accounts.restore_degraded_account(degraded.id)

      # Revocation is TWO things — the refresh family AND the issued access
      # tokens. Asserting only the family stays green while live tokens keep
      # working, which is the half that actually lets someone back in.
      assert live_family_count(degraded.id) == 0,
             "a change made from a stolen session is not undone while that session is open"

      assert guardian_token_count(degraded.id) == 0,
             "issued access tokens must be burned too, or the session survives the revoke"
    end

    test "refuses an account that is not degraded" do
      healthy = insert(:user, email_confirmed: true)
      assert {:error, :not_degraded} = Accounts.restore_degraded_account(healthy.id)
    end

    test "refuses an unknown user" do
      assert {:error, :user_not_found} =
               Accounts.restore_degraded_account(Ecto.UUID.generate())
    end

    # The audit guarantee is asserted where it is actually produced: a conn-level
    # test through the :admin pipeline in `admin_controller_test.exs`.
    #
    # A test lived here that called `Stacks.Audit.log` ITSELF and then asserted
    # the row existed. Deleting the controller's audit call left it green, so the
    # guarantee the runbook leans on — that un-degrading an account leaves a
    # trace naming the operator — was enforced by nothing. Removed rather than
    # patched: the context does not write that row, so this file is the wrong
    # place to claim it does.

    test "the restored account is no longer listed as degraded" do
      degraded = degraded_user()
      assert {:ok, _} = Accounts.restore_degraded_account(degraded.id)
      assert Accounts.list_degraded_accounts() == []
    end
  end

  defp live_family_count(user_id) do
    Repo.aggregate(
      from(f in Stacks.Accounts.AuthTokenFamily,
        where: f.user_id == ^user_id and is_nil(f.revoked_at)
      ),
      :count
    )
  end

  defp guardian_token_count(user_id) do
    Repo.aggregate(
      from(t in "guardian_tokens", prefix: "op", where: t.sub == ^to_string(user_id)),
      :count,
      :jti
    )
  end

  defp seed_guardian_token(user_id) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.insert_all(
      "guardian_tokens",
      [
        %{
          jti: Ecto.UUID.generate(),
          aud: "core",
          typ: "access",
          iss: "core",
          sub: to_string(user_id),
          exp: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_unix(),
          jwt: "review-probe-jwt",
          claims: %{},
          inserted_at: now,
          updated_at: now
        }
      ],
      prefix: "op"
    )
  end
end
