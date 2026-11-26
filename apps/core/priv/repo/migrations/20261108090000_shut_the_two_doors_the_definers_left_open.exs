defmodule Core.Repo.Migrations.ShutTheTwoDoorsTheDefinersLeftOpen do
  @moduledoc """
      Two `SECURITY DEFINER` functions were created without the protections
      their neighbours carry, and each gap was measured rather than inferred.

      ⛔ **ONE: `audit.scrub_for_erasure` is executable by PUBLIC.** `CREATE
      FUNCTION` grants EXECUTE to PUBLIC by default, so the named grant to the
      app role was decorative. Measured on the local database:

          proacl = {=X/postgres,postgres=X/postgres,stacks_app=X/postgres}
                    ^^^^^^^^^^^ PUBLIC
          has_function_privilege('stacks_dbt', 'audit.scrub_for_erasure(uuid)', 'EXECUTE') = true
          has_schema_privilege('stacks_dbt', 'audit', 'USAGE')                             = true
          has_table_privilege('stacks_dbt', 'audit.audit_log', 'UPDATE')                   = false

      That chain is complete: `stacks_dbt` is a LOGIN role with its own
      password, holds USAGE on `audit`, holds **no** direct UPDATE — and can
      reach the one function that writes. This is the only write path into an
      append-only forensic and GDPR record, and it stood open to the role whose
      entire documented posture is read-only. The append-only trigger does not
      stop it either: its gate is a custom GUC any role can `SET LOCAL`.

      ⚖️ Every other definer on this branch already revokes PUBLIC —
      `op.blocked_pair`'s ACL has no PUBLIC entry. This one was the exception.

      ⛔ **TWO: `op.count_others_sharing_all` lost its owner pin, and the
      assertion written to catch that cannot see it.** Replacing the 3-arg form
      with a 2-arg one is a fresh `CREATE`, so ownership fell to the migrating
      role: it is the only one of eight `op` definers not owned by
      `rls_reader`. The superseded migration's own moduledoc states the
      consequence — "a definer that was never reassigned runs as the migrating
      superuser in development and as nobody useful in production."

      ⚠️ This is a **dropped** guard, not a missing one. The correct helper,
      with owner transfer, PUBLIC revoke and five assertions, was sitting in the
      file being superseded; the replacement carried over only the revoke, as a
      bare `execute` with nothing asserting it. The guards that would have
      caught it key on the 3-arg signature and sort *earlier*, so both are
      structurally positioned where they cannot see the change that invalidated
      them — which is why this migration asserts in both directions rather than
      adding a sixth guard somewhere else.
  """
  use Ecto.Migration

  @audit_fn "audit.scrub_for_erasure(uuid)"
  @op_fn "op.count_others_sharing_all(uuid, integer)"
  @app_role "stacks_app"

  def up do
    execute(revoke_public(@audit_fn), "")
    execute(pin_owner(@op_fn), "")
    execute(revoke_public(@op_fn), "")
    execute(assert_shut(), "")
  end

  def down do
    # ⚖️ Deliberately not reversible. `down` would have to re-open a definer to
    # PUBLIC, which is not a state this repository should be able to roll back
    # into by accident. The forward step is idempotent, so re-running is safe.
    :ok
  end

  defp revoke_public(signature) do
    """
    DO $$ BEGIN
      IF to_regprocedure('#{signature}') IS NOT NULL THEN
        REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC;

        IF EXISTS (SELECT FROM pg_roles WHERE rolname = '#{@app_role}') THEN
          GRANT EXECUTE ON FUNCTION #{signature} TO #{@app_role};
        END IF;
      END IF;
    END $$;
    """
  end

  # ⚠️ NOT applied to the audit function, and the asymmetry is the point.
  # `OWNER TO rls_reader` is right for the `op` definers, which read across
  # users via GRANT SELECT. It would BREAK the audit scrub: `rls_reader` holds
  # no UPDATE on `audit.audit_log`, so a definer owned by it could not write.
  # The audit function's protection is the PUBLIC revoke above, not an owner
  # change.
  defp pin_owner(signature) do
    """
    DO $$ BEGIN
      IF to_regprocedure('#{signature}') IS NOT NULL
         AND EXISTS (SELECT FROM pg_roles WHERE rolname = 'rls_reader') THEN
        ALTER FUNCTION #{signature} OWNER TO rls_reader;
      END IF;
    END $$;
    """
  end

  # ⛔ ASSERTS, rather than trusting the statements above to have run. A grant
  # that silently did nothing is indistinguishable from one that worked, and
  # that is exactly how both of these reached a deployed branch.
  defp assert_shut do
    """
    DO $$ BEGIN
      -- ⚠️ PUBLIC is not a role name, so has_function_privilege cannot ask
      -- this; in the ACL a PUBLIC grant is the entry whose grantee oid is 0.
      IF to_regprocedure('#{@audit_fn}') IS NOT NULL AND EXISTS (
        SELECT 1
          FROM pg_proc pr, aclexplode(pr.proacl) AS a
         WHERE pr.oid = to_regprocedure('#{@audit_fn}')
           AND a.grantee = 0
           AND a.privilege_type = 'EXECUTE'
      ) THEN
        RAISE EXCEPTION 'audit.scrub_for_erasure is still executable by PUBLIC — the only write path into an append-only record is open to every role, including the read-only one';
      END IF;

      IF to_regprocedure('#{@op_fn}') IS NOT NULL AND EXISTS (
        SELECT 1
          FROM pg_proc pr, aclexplode(pr.proacl) AS a
         WHERE pr.oid = to_regprocedure('#{@op_fn}')
           AND a.grantee = 0
           AND a.privilege_type = 'EXECUTE'
      ) THEN
        RAISE EXCEPTION 'op.count_others_sharing_all is still executable by PUBLIC, which makes every named grant decorative';
      END IF;

      IF to_regprocedure('#{@op_fn}') IS NOT NULL
         AND EXISTS (SELECT FROM pg_roles WHERE rolname = 'rls_reader')
         AND (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid = to_regprocedure('#{@op_fn}')) <> 'rls_reader' THEN
        RAISE EXCEPTION 'op.count_others_sharing_all is not owned by rls_reader, so it runs as whoever migrated rather than as the reader role';
      END IF;
    END $$;
    """
  end
end
