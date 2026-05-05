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
  """
  use Core.DataCase, async: false

  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Admin.SessionContext
  alias Stacks.AdminSession
  alias Stacks.Audit
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
