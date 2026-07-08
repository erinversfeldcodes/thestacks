defmodule Stacks.AuditAppendOnlyTest do
  @moduledoc """
  Integration tests for the DB-level append-only trigger on
  `audit.audit_log` (Issue #138 Phase 1).

  The trigger is `BEFORE UPDATE OR DELETE` and raises an exception unless
  the session GUC `app.audit_gdpr_erasure` equals `'true'`. It applies to
  ALL roles (including `neondb_owner`); the only authorised mutation path
  is the GDPR erasure flow, which sets the GUC inside its `Ecto.Multi`
  before issuing UPDATE/DELETE.

  Until the migration adding the trigger lands, these tests fail because
  raw UPDATE/DELETE succeed (no exception raised).
  """
  use Core.DataCase, async: false

  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Audit

  # Insert a row, then return its raw id binary (suitable for $1-style
  # parameter binding in Repo.query).
  defp insert_audit_row do
    user = insert(:user)
    {:ok, entry} = Audit.log(user.id, "test.append_only", resource_type: "user")
    Ecto.UUID.dump!(entry.id)
  end

  describe "append-only trigger" do
    test "raw UPDATE on audit.audit_log is blocked" do
      id = insert_audit_row()

      # Without the GUC set, UPDATE must raise. We expect a Postgrex error
      # whose message contains the trigger's RAISE EXCEPTION text. The
      # exact wording is implementation-defined, but it MUST mention
      # append-only / audit / immutable so an operator can identify it.
      assert {:error, %Postgrex.Error{} = err} =
               Repo.query(
                 "UPDATE audit.audit_log SET action = $1 WHERE id = $2",
                 ["tampered.action", id]
               )

      msg = Postgrex.Error.message(err) |> String.downcase()

      assert msg =~ "append" or msg =~ "audit" or msg =~ "immutable" or msg =~ "gdpr",
             "expected trigger error message to mention append/audit/immutable/gdpr, got: #{msg}"
    end

    test "raw DELETE on audit.audit_log is blocked" do
      id = insert_audit_row()

      assert {:error, %Postgrex.Error{} = err} =
               Repo.query("DELETE FROM audit.audit_log WHERE id = $1", [id])

      msg = Postgrex.Error.message(err) |> String.downcase()

      assert msg =~ "append" or msg =~ "audit" or msg =~ "immutable" or msg =~ "gdpr",
             "expected trigger error message to mention append/audit/immutable/gdpr, got: #{msg}"
    end

    test "UPDATE allowed when app.audit_gdpr_erasure GUC is set inside a transaction" do
      id = insert_audit_row()

      # The GDPR erasure path uses SET LOCAL inside a transaction. Mirror
      # that here. With the GUC set to 'true', the trigger must allow the
      # UPDATE through.
      result =
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL app.audit_gdpr_erasure = 'true'")

          Repo.query!("UPDATE audit.audit_log SET action = $1 WHERE id = $2", [
            "user.data_redacted",
            id
          ])

          :ok
        end)

      assert {:ok, :ok} = result
    end

    test "DELETE allowed when app.audit_gdpr_erasure GUC is set inside a transaction" do
      id = insert_audit_row()

      result =
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL app.audit_gdpr_erasure = 'true'")
          Repo.query!("DELETE FROM audit.audit_log WHERE id = $1", [id])
          :ok
        end)

      assert {:ok, :ok} = result
    end

    test "trigger blocks even from privileged roles (GUC, not role, is the gate)" do
      # The trigger logic doesn't allowlist by role — only by GUC. So any
      # role hitting it without the GUC set is blocked, including the role
      # the test connection runs as (whatever Ecto is configured to in
      # test.exs). This guards the principle: even an attacker with stolen
      # `neondb_owner` credentials cannot mutate the audit log without
      # also setting the GDPR erasure GUC, which is itself a recorded act.
      id = insert_audit_row()

      assert {:error, %Postgrex.Error{}} =
               Repo.query(
                 "UPDATE audit.audit_log SET action = $1 WHERE id = $2",
                 ["neondb_owner_tamper", id]
               )
    end

    test "GUC set with SET LOCAL does not leak past the transaction boundary" do
      # Crucial: the GDPR path uses SET LOCAL (transaction-scoped), not SET
      # (session-scoped). After a multi commits or rolls back, a subsequent
      # UPDATE on a fresh transaction must again be blocked.
      id1 = insert_audit_row()
      id2 = insert_audit_row()

      # First transaction: GUC set, UPDATE permitted.
      assert {:ok, :ok} =
               Repo.transaction(fn ->
                 Repo.query!("SET LOCAL app.audit_gdpr_erasure = 'true'")

                 Repo.query!("UPDATE audit.audit_log SET action = $1 WHERE id = $2", [
                   "user.data_redacted",
                   id1
                 ])

                 :ok
               end)

      # Second transaction: no GUC, UPDATE must be blocked.
      assert {:error, %Postgrex.Error{}} =
               Repo.query("UPDATE audit.audit_log SET action = $1 WHERE id = $2", [
                 "should_not_apply",
                 id2
               ])
    end
  end
end
