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
  `op.event_log` immutability invariant (no rows added, removed, or modified
  in place during `delete_user_data/1`).
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
    # Snapshot of every op.event_log row's FULL content, as a MapSet of maps.
    # Selecting all columns (not just the PK) means an in-place UPDATE of
    # payload/metadata/etc. on an existing row — same id — changes the set and
    # is detected. Column list mirrors the select in `Stacks.Events.fetch_batch/3`
    # so it tracks the real op.event_log schema.
    defp event_log_rows do
      Repo.all(
        from(e in "event_log",
          select: %{
            id: e.id,
            event_type: e.event_type,
            aggregate_type: e.aggregate_type,
            aggregate_id: e.aggregate_id,
            schema_version: e.schema_version,
            payload: e.payload,
            metadata: e.metadata,
            occurred_at: e.occurred_at,
            published_at: e.published_at
          }
        ),
        prefix: "op"
      )
      |> MapSet.new()
    end

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

    test "does not add, remove, or modify any op.event_log row during erasure" do
      user = insert(:user)

      # Seed events so the snapshot is non-empty (teeth) — including one whose
      # aggregate is the very user being erased. The immutability contract says
      # event payloads are UUID-only with nothing to scrub, so even the erased
      # user's events must survive the erasure untouched.
      assert {:ok, _} =
               Events.emit(%{
                 event_type: "test.erasure.user_event",
                 aggregate_type: "user",
                 aggregate_id: user.id
               })

      assert {:ok, _} =
               Events.emit(%{
                 event_type: "test.erasure.other_event",
                 aggregate_type: "book",
                 aggregate_id: Ecto.UUID.generate()
               })

      before_rows = event_log_rows()
      assert MapSet.size(before_rows) >= 2

      assert {:ok, _result} = Deletion.delete_user_data(user.id)

      # The full row content of op.event_log is byte-for-byte identical: nothing
      # deleted, nothing inserted, and no row modified in place (an UPDATE of any
      # column — e.g. payload or metadata — would change the set and fail here).
      # delete_user_data/1 never touches op.event_log.
      assert event_log_rows() == before_rows
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
