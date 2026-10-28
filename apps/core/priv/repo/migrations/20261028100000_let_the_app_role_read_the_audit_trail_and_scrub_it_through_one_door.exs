defmodule Core.Repo.Migrations.LetTheAppRoleReadTheAuditTrailAndScrubItThroughOneDoor do
  @moduledoc """
      Gives `stacks_app` SELECT on `audit.audit_log`, and a single
      SECURITY DEFINER door for the one mutation erasure needs.

      ## The gap, and why it was two defects

      The predecessor roles migration states the posture plainly —
      "CRUD on the operational schema, append-only on the audit trail" — and
      implements it as:

          GRANT INSERT ON ALL TABLES IN SCHEMA audit TO stacks_app;
          REVOKE UPDATE, DELETE ON audit.audit_log FROM stacks_app;

      That is a deliberate decision, and it is not wrong. What was never
      reconciled is that **two** other deliberate decisions need more than
      INSERT on that table:

        * the GDPR audit surface (`GET /api/settings/audit-log`) must SELECT it;
        * erasure must SCRUB it — `metadata` and `ip_address` to NULL — which is
          an UPDATE, authorised by the `app.audit_gdpr_erasure` protocol built
          for exactly that purpose.

      Measured on a deployed stack 2026-10-28, with the runtime pools connected
      as `stacks_app`:

          information_schema.table_privileges, audit.audit_log, stacks_app
            → INSERT          (and nothing else)
          has_table_privilege('stacks_app','audit.audit_log','SELECT')
            → false

      ⛔ **Consequence 1 — the right to erasure was non-functional.** The scrub
      runs inside the erasure `Ecto.Multi`, *after* `repo.delete(user)`, so the
      permission error aborted the whole transaction and the user was never
      deleted. `AccountDeletionJob` has `max_attempts: 1`, so the job went
      straight to `discarded` with no retry and no alert, while the caller had
      already been told "Account deletion has been queued." Driven end to end:
      202 accepted, then ten consecutive 200s from an authenticated endpoint
      over 30 seconds, and this in `oban_jobs.errors`:

          ERROR 42501 (insufficient_privilege) permission denied for table audit_log
          lib/stacks/gdpr/deletion.ex:282

      ⛔ **Consequence 2 — the audit surface answered a confident lie.** Both
      reads in `Audit.list_for_user/2` mapped every error to an empty success, so
      a refused query was reported as `200 {"total":0,"entries":[]}`. That
      swallowing is removed in the same change as this migration; this grant is
      what makes the now-loud path succeed instead of 500.

      ## Why SELECT is granted but UPDATE is not

      The append-only posture stays true **at the role level**, which is the
      level where it is worth defending: a bug or an injection in application
      code cannot reach an audit row's columns at all.

      The scrub instead goes through `audit.scrub_for_erasure/1`, a
      SECURITY DEFINER function that is strictly narrower than the UPDATE grant
      it replaces. The grant would have permitted any column of any row to be
      rewritten whenever the GUC happened to be armed. The function permits
      exactly two columns, selected by exactly one `user_id`, and cannot delete
      a row or touch `action`, `resource_type`, `resource_id` or `occurred_at`.

      ⚠️ **The authorisation protocol is deliberately UNCHANGED.** The function
      does **not** arm `app.audit_gdpr_erasure` itself; it still requires the
      caller to have armed it, exactly as the direct UPDATE did. That protocol —
      `SET LOCAL` to arm, a statement-level AFTER trigger to disarm, so one
      authorisation covers one statement — is already built and already tested,
      and this migration is about supplying a missing *privilege*, not about
      redesigning the *authorisation*. Self-arming inside the function would
      have been tighter in one respect and would also have quietly replaced a
      tested mechanism with an untested one, in a migration whose subject is
      something else.

      ## Why a new migration rather than editing the predecessor

      The predecessor has already run on every database that matters, so an edit
      would never be picked up there. A separate migration applies everywhere
      exactly once regardless of what each database has already seen. This is
      the same reasoning the Oban grants migration records, and this is the
      third time switching the runtime pools to `stacks_app` has revealed a
      grant nobody gave — `public.oban_jobs` was the first, its sequence the
      second. ⛔ The reason it keeps happening is that **no local or CI run
      connects as `stacks_app`**, so a missing grant is invisible until a
      deployed stack hits it. That is tracked as its own piece of work; until it
      is built, a migration like this one is the only place the privilege can be
      asserted at all.

      ## The far-end assertion

      Guarded on the grantee, because a developer database legitimately has no
      `stacks_app` — and then asserted, because a grant guarded by `IF EXISTS`
      on its own grantee reports success when its subject is missing. That is
      how the March roles migration passed for months while granting nothing.
  """
  use Ecto.Migration

  @app_role "stacks_app"

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    execute(scrub_function_up(), scrub_function_down())
    execute(grants_up(), grants_down())
    execute(assert_granted())
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute(grants_down())
    execute(scrub_function_down())
  end

  # ⚠️ `search_path` is pinned. A SECURITY DEFINER function without it resolves
  # unqualified names against the CALLER's search_path, which is how a definer
  # becomes a privilege-escalation primitive. Every name below is also
  # schema-qualified, so the pin is the second of two defences rather than the
  # only one.
  defp scrub_function_up do
    """
    CREATE OR REPLACE FUNCTION audit.scrub_for_erasure(p_user_id uuid)
      RETURNS integer
      LANGUAGE plpgsql
      SECURITY DEFINER
      SET search_path = pg_catalog
    AS $$
    DECLARE
      scrubbed integer;
    BEGIN
      IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'audit.scrub_for_erasure requires a user id; a NULL would match no rows and report success';
      END IF;

      -- ⛔ Deliberately does NOT arm app.audit_gdpr_erasure. The caller arms it
      -- with SET LOCAL and the statement-level trigger disarms it, so one
      -- authorisation covers one statement. If the caller has not armed it, the
      -- append-only trigger refuses this UPDATE and that refusal is correct.
      UPDATE audit.audit_log
         SET metadata = NULL,
             ip_address = NULL
       WHERE user_id = p_user_id;

      GET DIAGNOSTICS scrubbed = ROW_COUNT;
      RETURN scrubbed;
    END;
    $$;
    """
  end

  defp scrub_function_down do
    "DROP FUNCTION IF EXISTS audit.scrub_for_erasure(uuid);"
  end

  defp grants_up do
    """
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = '#{@app_role}') THEN
        GRANT USAGE ON SCHEMA audit TO #{@app_role};
        GRANT SELECT ON audit.audit_log TO #{@app_role};

        -- The one door for the one mutation erasure needs.
        GRANT EXECUTE ON FUNCTION audit.scrub_for_erasure(uuid) TO #{@app_role};

        -- Restated, not assumed: the posture this migration preserves.
        REVOKE UPDATE, DELETE, TRUNCATE ON audit.audit_log FROM #{@app_role};
      END IF;
    END $$;
    """
  end

  defp grants_down do
    """
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = '#{@app_role}') THEN
        REVOKE EXECUTE ON FUNCTION audit.scrub_for_erasure(uuid) FROM #{@app_role};
        REVOKE SELECT ON audit.audit_log FROM #{@app_role};
      END IF;
    END $$;
    """
  end

  # ⛔ The far end. Four claims, each the inverse of a way this migration could
  # report success while leaving the system broken: the read still refused, the
  # door missing, or the append-only posture quietly widened by this very file.
  defp assert_granted do
    """
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = '#{@app_role}')
         AND to_regclass('audit.audit_log') IS NOT NULL THEN

        IF NOT has_table_privilege('#{@app_role}', 'audit.audit_log', 'SELECT') THEN
          RAISE EXCEPTION
            'role #{@app_role} still cannot SELECT audit.audit_log, so the GDPR audit surface would keep reporting an empty history for every reader';
        END IF;

        IF NOT has_function_privilege('#{@app_role}', 'audit.scrub_for_erasure(uuid)', 'EXECUTE') THEN
          RAISE EXCEPTION
            'role #{@app_role} cannot execute audit.scrub_for_erasure, so account erasure would still abort and be discarded on its only attempt';
        END IF;

        IF has_table_privilege('#{@app_role}', 'audit.audit_log', 'UPDATE') THEN
          RAISE EXCEPTION
            'role #{@app_role} can UPDATE audit.audit_log directly — this migration is supposed to keep the audit trail append-only at the role level and route the scrub through one function';
        END IF;

        IF has_table_privilege('#{@app_role}', 'audit.audit_log', 'DELETE') THEN
          RAISE EXCEPTION
            'role #{@app_role} can DELETE from audit.audit_log — audit rows are never deleted, only scrubbed';
        END IF;
      END IF;
    END $$;
    """
  end
end
