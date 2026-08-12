defmodule Stacks.AuditAppendOnlyTest do
  @moduledoc """
      Integration tests for the DB-level append-only trigger on
      `audit.audit_log`.

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

  defp insert_audit_row do
    user = insert(:user)
    {:ok, entry} = Audit.log(user.id, "test.append_only", resource_type: "user")
    Ecto.UUID.dump!(entry.id)
  end

  describe "append-only trigger" do
    test "raw UPDATE on audit.audit_log is blocked" do
      id = insert_audit_row()

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
      id = insert_audit_row()

      assert {:error, %Postgrex.Error{}} =
               Repo.query(
                 "UPDATE audit.audit_log SET action = $1 WHERE id = $2",
                 ["neondb_owner_tamper", id]
               )
    end

    test "GUC set with SET LOCAL does not leak past the transaction boundary" do
      id1 = insert_audit_row()
      id2 = insert_audit_row()

      assert {:ok, :ok} =
               Repo.transaction(fn ->
                 Repo.query!("SET LOCAL app.audit_gdpr_erasure = 'true'")

                 Repo.query!("UPDATE audit.audit_log SET action = $1 WHERE id = $2", [
                   "user.data_redacted",
                   id1
                 ])

                 :ok
               end)

      assert {:error, %Postgrex.Error{}} =
               Repo.query("UPDATE audit.audit_log SET action = $1 WHERE id = $2", [
                 "should_not_apply",
                 id2
               ])
    end
  end
end
