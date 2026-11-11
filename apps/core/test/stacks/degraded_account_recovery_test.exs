defmodule Stacks.DegradedAccountRecoveryTest do
  use Core.DataCase, async: false

  import Ecto.Query, only: [from: 2]
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

  describe "who reverted the email change" do
    # ⛔ The two reverts emit the SAME event type, and for a while they emitted
    # the same empty payload too. A consumer counting reader-initiated undos
    # silently included operator interventions, and the only attribution lived
    # in an `admin.account_restored` audit row — a different table that no event
    # consumer reads.
    #
    # ⚠️ Asserted as a PAIR, deliberately. Checking only the operator path would
    # pass against a payload that tagged every revert `"operator"`, which is the
    # same defect inverted: a reader's undo attributed to staff. The property is
    # that the two paths are DISTINGUISHABLE, so both halves have to be read.
    test "an operator restore and a reader undo are distinguishable in the payload" do
      operator_user = degraded_user()
      assert {:ok, _} = Accounts.restore_degraded_account(operator_user.id)

      # ⚠️ A SIGNED token, not the factory's opaque `"rev-N"` placeholder.
      # `revert_email_change/1` verifies the token before it does anything, so
      # the placeholder yields `{:error, :invalid}` and the reader half of this
      # assertion would never run — the test would have passed while reading
      # only the operator path, which is precisely the one-sided check the note
      # above warns against.
      reader_user = degraded_user(pending_email_revert_token: nil)

      {:ok, reader_user} =
        reader_user
        |> Accounts.pending_email_changeset(%{
          pending_email_revert_token: Accounts.sign_email_revert_token(reader_user.id)
        })
        |> Core.Repo.update()

      assert {:ok, _} =
               Stacks.Email.revert_email_change(reader_user.pending_email_revert_token)

      assert revert_initiators(operator_user.id) == ["operator"],
             "the operator restore did not record itself as operator-initiated"

      assert revert_initiators(reader_user.id) == ["reader"],
             "the reader's own undo was not recorded as reader-initiated — if this says " <>
               "\"operator\", every revert is now attributed to staff, which is the original " <>
               "defect inverted rather than fixed"
    end

    test "the payload carries the contract's version, so a v1 consumer is not misled" do
      user = degraded_user()
      assert {:ok, _} = Accounts.restore_degraded_account(user.id)

      # v1 of this event had no `initiated_by` at all. A v2 payload arriving
      # labelled v1 would tell a consumer the key cannot be there when it is.
      assert revert_versions(user.id) == [2]
    end
  end

  defp revert_initiators(user_id) do
    Core.Repo.all(
      from(e in "event_log",
        prefix: "op",
        where: e.event_type == "user.email_change_reverted" and e.aggregate_id == ^user_id,
        select: fragment("?->>'initiated_by'", e.payload)
      )
    )
  end

  defp revert_versions(user_id) do
    Core.Repo.all(
      from(e in "event_log",
        prefix: "op",
        where: e.event_type == "user.email_change_reverted" and e.aggregate_id == ^user_id,
        select: e.schema_version
      )
    )
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
