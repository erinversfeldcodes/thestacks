defmodule Stacks.AuditAppendOnlyTest do
  @moduledoc """
      Integration tests for the DB-level append-only trigger on
      `audit.audit_log`.

      A `BEFORE UPDATE OR DELETE` row trigger raises unless the session GUC
      `app.audit_gdpr_erasure` equals `'true'`. It applies to ALL roles
      (including `neondb_owner`); the only authorised mutation path is the GDPR
      erasure flow, which sets the GUC inside its `Ecto.Multi` before issuing
      UPDATE/DELETE.

      Authorisation is consumed per STATEMENT: an `AFTER … FOR EACH STATEMENT`
      trigger resets the GUC once the authorised statement finishes, so one
      grant covers every row a scrub touches but cannot outlive it — which
      matters under the savepoint sandbox, where `SET LOCAL` survives a
      released savepoint.
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

  defp actions_of(ids) do
    %{rows: rows} =
      Repo.query!(
        "SELECT action FROM audit.audit_log WHERE id = ANY($1) ORDER BY action",
        [ids]
      )

    List.flatten(rows)
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

    test "one authorisation covers every row of a scrub, not just the first" do
      id1 = insert_audit_row()
      id2 = insert_audit_row()

      assert {:ok, 2} =
               Repo.transaction(fn ->
                 Repo.query!("SET LOCAL app.audit_gdpr_erasure = 'true'")

                 %{num_rows: n} =
                   Repo.query!(
                     "UPDATE audit.audit_log SET action = $1 WHERE id = ANY($2)",
                     ["user.data_redacted", [id1, id2]]
                   )

                 n
               end)

      assert actions_of([id1, id2]) == ["user.data_redacted", "user.data_redacted"]
    end

    test "an authorised UPDATE actually writes the new value" do
      id = insert_audit_row()

      Repo.transaction(fn ->
        Repo.query!("SET LOCAL app.audit_gdpr_erasure = 'true'")
        Repo.query!("UPDATE audit.audit_log SET action = $1 WHERE id = $2", ["scrubbed", id])
      end)

      assert actions_of([id]) == ["scrubbed"]
    end

    test "a multi-row DELETE removes every row, not just the first" do
      id1 = insert_audit_row()
      id2 = insert_audit_row()

      assert {:ok, 2} =
               Repo.transaction(fn ->
                 Repo.query!("SET LOCAL app.audit_gdpr_erasure = 'true'")

                 %{num_rows: n} =
                   Repo.query!("DELETE FROM audit.audit_log WHERE id = ANY($1)", [[id1, id2]])

                 n
               end)

      assert actions_of([id1, id2]) == []
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
