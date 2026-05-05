defmodule Core.Repo.Migrations.AuditLogAppendOnlyTrigger do
  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION audit.audit_log_append_only()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF current_setting('app.audit_gdpr_erasure', true) = 'true' THEN
        -- Reset the GUC immediately so it cannot leak beyond the row that
        -- authorised this operation. This is a defence-in-depth measure for
        -- savepoint-based test environments where SET LOCAL does not roll back
        -- on RELEASE SAVEPOINT. In production (real transactions) SET LOCAL
        -- resets naturally at transaction end regardless.
        PERFORM set_config('app.audit_gdpr_erasure', 'false', true);
        RETURN OLD;
      END IF;
      RAISE EXCEPTION 'audit.audit_log is append-only; UPDATE/DELETE are blocked. '
        'To authorise a GDPR erasure mutation, set the app.audit_gdpr_erasure GUC '
        'to ''true'' inside the erasure transaction (SET LOCAL).';
    END;
    $$;
    """)

    execute("""
    CREATE TRIGGER audit_log_append_only
    BEFORE UPDATE OR DELETE ON audit.audit_log
    FOR EACH ROW EXECUTE FUNCTION audit.audit_log_append_only();
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS audit_log_append_only ON audit.audit_log;")
    execute("DROP FUNCTION IF EXISTS audit.audit_log_append_only();")
  end
end
