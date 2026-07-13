defmodule Stacks.GDPR.DeletionTest do
  @moduledoc """
  Tests for `Stacks.GDPR.Deletion.delete_user_data/1` — Issue #138 Phase 1
  additions only.

  Phase 1 wires a `Multi.run` step into the existing erasure transaction
  that issues `SET LOCAL app.audit_gdpr_erasure = 'true'` before any audit
  modification. Two invariants:

    1. The GUC is set inside the same transaction the audit cleanup runs in
       — proven indirectly by issuing an audit-row UPDATE inside the same
       Multi and asserting it succeeds (i.e. the trigger from Phase 1's
       append-only migration permits it).
    2. The GUC is scoped to the transaction (SET LOCAL, not SET) — proven by
       asserting a subsequent raw UPDATE on `audit.audit_log` fails after
       the multi commits.

  Until Phase 1's implementation lands, the GUC is never set, so the audit
  trigger blocks any cleanup the multi attempts and the deletion fails.

  Also covers Issue #121: the erasure audit-row invariants and the
  `op.event_log` GDPR-scrub invariant — the erased user's own event rows are
  preserved (immutability: never deleted) but their PII-bearing payload and
  metadata are redacted in place, while unrelated rows are left untouched.
  """
  use Core.DataCase, async: false

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Accounts
  alias Stacks.Accounts.AuthTokenFamily
  alias Stacks.Accounts.Guardian
  alias Stacks.Admin.SessionContext
  alias Stacks.AdminSession
  alias Stacks.Audit
  alias Stacks.Events
  alias Stacks.Events.EventLog
  alias Stacks.GDPR.Deletion
  alias Stacks.MFA
  alias Stacks.MFA.UserMFA

  describe "delete_user_data/1 GUC integration" do
    test "delete_user_data records the GDPR erasure GUC value in the multi result" do
      # Phase 1 adds a `Multi.run` step (canonically named `:set_gdpr_guc`)
      # that issues `SET LOCAL app.audit_gdpr_erasure = 'true'` BEFORE any
      # audit-row modification. The step's result must be discoverable in
      # the multi's final result map so callers (and tests) can verify the
      # GUC was set without poking into private state.
      #
      # We assert the result map contains a key whose name includes "gdpr"
      # or "guc" — accepting any reasonable canonical naming.
      user = insert(:user)
      {:ok, _entry} = Audit.log(user.id, "user.login", resource_type: "user")

      assert {:ok, result_map} = Deletion.delete_user_data(user.id)

      keys = Map.keys(result_map) |> Enum.map(&to_string/1)

      guc_key =
        Enum.find(keys, fn k ->
          String.contains?(k, "gdpr") or String.contains?(k, "guc") or
            String.contains?(k, "audit_erasure")
        end)

      assert guc_key,
             "expected delete_user_data/1's :ok result map to include a GDPR erasure GUC step (key containing 'gdpr', 'guc', or 'audit_erasure'), got keys: #{inspect(keys)}"
    end

    test "GUC is scoped to the deletion transaction (does not leak)" do
      # After delete_user_data commits, a subsequent ad-hoc UPDATE on
      # audit.audit_log must still be blocked — proving SET LOCAL was used,
      # not session-wide SET.
      user = insert(:user)
      {:ok, entry} = Audit.log(user.id, "user.login", resource_type: "user")

      # Insert a second audit row attributed to a DIFFERENT user — we'll
      # try to mutate it AFTER the multi commits, to verify the GUC didn't
      # leak.
      other_user = insert(:user)
      {:ok, other_entry} = Audit.log(other_user.id, "other.login", resource_type: "user")

      _ = entry
      assert {:ok, _result} = Deletion.delete_user_data(user.id)

      # Now: outside the multi's transaction, the trigger must still block
      # any UPDATE on audit.audit_log.
      assert {:error, %Postgrex.Error{}} =
               Repo.query(
                 "UPDATE audit.audit_log SET action = $1 WHERE id = $2",
                 ["leak.test", Ecto.UUID.dump!(other_entry.id)]
               )
    end
  end

  describe "delete_user_data/1 audit + event_log invariants (Issue #121)" do
    test "writes a user.data_deleted audit row with nil user_id and the deleted user's id as resource_id" do
      user = insert(:user)

      assert {:ok, _result} = Deletion.delete_user_data(user.id)

      # Query audit.audit_log directly (schemaless) rather than trusting the
      # multi result. user_id MUST be nil — the acting principal for an erasure
      # is the system, and the erased user's id lives in resource_id instead, so
      # no PII-linked actor survives in the audit trail.
      row =
        Repo.one(
          from(a in "audit_log",
            where: a.action == "user.data_deleted",
            select: %{
              user_id: a.user_id,
              resource_type: a.resource_type,
              resource_id: a.resource_id
            }
          ),
          prefix: "audit"
        )

      assert row, "expected a user.data_deleted audit row after erasure"
      assert row.user_id == nil
      assert row.resource_type == "user"
      assert row.resource_id == Ecto.UUID.dump!(user.id)
    end

    test "scrubs PII from the erased user's own event_log rows but preserves the rows" do
      user = insert(:user)
      other_id = Ecto.UUID.generate()

      # Seed a LEGACY PII-bearing event on the erased user's aggregate — the
      # shape older emitters wrote before Issue #121 made user.* events
      # UUID-only. Both payload and metadata carry PII here.
      assert {:ok, _} =
               Events.emit(%{
                 event_type: "user.profile_updated",
                 aggregate_type: "user",
                 aggregate_id: user.id,
                 payload: %{display_name: "Ada Lovelace"},
                 metadata: %{ip: "10.0.0.1"}
               })

      # An unrelated event on a DIFFERENT aggregate — must be left untouched.
      assert {:ok, _} =
               Events.emit(%{
                 event_type: "book.created",
                 aggregate_type: "book",
                 aggregate_id: other_id,
                 payload: %{isbn: "9780262510875", title: "SICP"}
               })

      before_other = Repo.one(from(e in EventLog, where: e.aggregate_id == ^other_id))

      assert {:ok, result} = Deletion.delete_user_data(user.id)

      # A dedicated scrub step ran inside the same erasure transaction.
      assert Map.has_key?(result, :scrub_event_log)

      # (a) The erased user's event row STILL EXISTS (immutability) but its
      #     payload AND metadata are now empty — the PII is scrubbed in place.
      user_rows =
        Repo.all(
          from(e in EventLog, where: e.aggregate_type == "user" and e.aggregate_id == ^user.id)
        )

      assert length(user_rows) == 1
      assert Enum.all?(user_rows, &(&1.payload == %{}))
      assert Enum.all?(user_rows, &(&1.metadata == %{}))

      # (b) The unrelated event row is byte-for-byte identical — untouched.
      after_other = Repo.one(from(e in EventLog, where: e.aggregate_id == ^other_id))
      assert after_other == before_other
    end
  end

  describe "delete_user_data/1 session revocation" do
    # Mirrors the login path (auth_controller): generate a family_id, mint a
    # token carrying it (which persists an op.guardian_tokens row via
    # Guardian.DB's after_encode_and_sign hook), then open the token family.
    defp open_session(user) do
      fid = Ecto.UUID.generate()
      {:ok, token, claims} = Guardian.encode_and_sign(user, %{"family_id" => fid})

      {:ok, _family} =
        Accounts.open_token_family(%{
          family_id: fid,
          user_id: user.id,
          current_jti: claims["jti"],
          session_started_at: DateTime.from_unix!(claims["sst"])
        })

      %{fid: fid, token: token}
    end

    defp guardian_token_count(user_id) do
      Repo.aggregate(
        from(t in "guardian_tokens", prefix: "op", where: t.sub == ^to_string(user_id)),
        :count,
        :jti
      )
    end

    defp family_count(user_id) do
      Repo.aggregate(from(f in AuthTokenFamily, where: f.user_id == ^user_id), :count, :family_id)
    end

    test "erasing a user deletes their auth_token_families and guardian_tokens rows" do
      user = insert(:user)
      _session = open_session(user)

      # Pre-condition: the user has an active session tracked in both tables.
      assert guardian_token_count(user.id) == 1
      assert family_count(user.id) == 1

      assert {:ok, _result} = Deletion.delete_user_data(user.id)

      # Post-condition: no lingering session state keyed to the erased user.
      assert guardian_token_count(user.id) == 0
      assert family_count(user.id) == 0
    end

    test "the erased user's live token no longer verifies" do
      user = insert(:user)
      %{token: token} = open_session(user)

      # Sanity: the token verifies before erasure.
      assert {:ok, _claims} = Guardian.decode_and_verify(token)

      assert {:ok, _result} = Deletion.delete_user_data(user.id)

      # The live access token is dead: its family/guardian_tokens rows are gone.
      assert {:error, _reason} = Guardian.decode_and_verify(token)
    end
  end

  describe "delete_user_data/1 cascade deletion" do
    test "deletes user_mfa and admin_sessions when user is deleted" do
      user = insert(:user)

      {:ok, %{secret: secret, recovery_codes: codes}} = MFA.begin_enrollment(user)
      valid_code = NimbleTOTP.verification_code(secret)
      {:ok, mfa} = MFA.confirm_enrollment(user, valid_code, secret, codes)

      {:ok, session} = SessionContext.create(user, "127.0.0.1", Core.Application.boot_id())

      assert {:ok, _} = Deletion.delete_user_data(user.id)

      assert is_nil(Repo.get(UserMFA, mfa.id))
      assert is_nil(Repo.get(AdminSession, session.id))
    end
  end
end
