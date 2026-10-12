defmodule Core.Repo.Migrations.AuditScrubAuthorisationSpansTheStatement do
  @moduledoc """
      The append-only guard on `audit.audit_log` disarmed itself inside the
      BEFORE-ROW trigger, so an authorised scrub only ever covered its FIRST
      row: row two saw the GUC already reset and raised, aborting the whole
      erasure. The same trigger returned `OLD` on UPDATE, which for a BEFORE
      trigger is the row that gets written — so even the one row it did allow
      was silently written back unchanged.

      Authorisation is now consumed per STATEMENT rather than per row: the row
      trigger checks the GUC and returns the correct row for the operation, and
      a statement-level AFTER trigger resets the GUC once the statement is
      done. That keeps the original defence-in-depth (an authorisation cannot
      outlive the operation it was granted for, including under the savepoint
      sandbox where `SET LOCAL` survives a released savepoint) while letting a
      scrub cover all of a user's rows in one pass.
  """
  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION audit.audit_log_append_only()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF current_setting('app.audit_gdpr_erasure', true) = 'true' THEN
        IF TG_OP = 'DELETE' THEN
          RETURN OLD;
        END IF;
        RETURN NEW;
      END IF;
      RAISE EXCEPTION 'audit.audit_log is append-only; UPDATE/DELETE are blocked. '
        'To authorise a GDPR erasure mutation, set the app.audit_gdpr_erasure GUC '
        'to ''true'' inside the erasure transaction (SET LOCAL).';
    END;
    $$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION audit.audit_log_disarm_gdpr()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      PERFORM set_config('app.audit_gdpr_erasure', 'false', true);
      RETURN NULL;
    END;
    $$;
    """)

    execute("DROP TRIGGER IF EXISTS audit_log_disarm_gdpr ON audit.audit_log;")

    execute("""
    CREATE TRIGGER audit_log_disarm_gdpr
    AFTER UPDATE OR DELETE ON audit.audit_log
    FOR EACH STATEMENT EXECUTE FUNCTION audit.audit_log_disarm_gdpr();
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS audit_log_disarm_gdpr ON audit.audit_log;")
    execute("DROP FUNCTION IF EXISTS audit.audit_log_disarm_gdpr();")

    execute("""
    CREATE OR REPLACE FUNCTION audit.audit_log_append_only()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF current_setting('app.audit_gdpr_erasure', true) = 'true' THEN
        PERFORM set_config('app.audit_gdpr_erasure', 'false', true);
        RETURN OLD;
      END IF;
      RAISE EXCEPTION 'audit.audit_log is append-only; UPDATE/DELETE are blocked. '
        'To authorise a GDPR erasure mutation, set the app.audit_gdpr_erasure GUC '
        'to ''true'' inside the erasure transaction (SET LOCAL).';
    END;
    $$;
    """)
  end
end
