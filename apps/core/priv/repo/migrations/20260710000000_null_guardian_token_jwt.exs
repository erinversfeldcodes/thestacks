defmodule Core.Repo.Migrations.NullGuardianTokenJwt do
  @moduledoc """
  Issue #174 — never persist the raw signed bearer token in op.guardian_tokens.jwt.
  guardian_db writes the full token into `jwt`, but the verify/revoke/purge path
  never reads it (verify by jti+aud, purge by exp), so a SELECT-capable compromise
  of this table yields replayable sessions. A BEFORE INSERT OR UPDATE trigger forces
  jwt = NULL at the data layer — enforced regardless of code path (login, the future
  refresh in #173, anything). Existing rows are scrubbed. The column stays (it is
  guardian_db's schema); it is simply always NULL.
  """
  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION op.guardian_tokens_null_jwt()
    RETURNS trigger AS $$
    BEGIN
      NEW.jwt := NULL;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER guardian_tokens_null_jwt_trigger
    BEFORE INSERT OR UPDATE ON op.guardian_tokens
    FOR EACH ROW
    EXECUTE FUNCTION op.guardian_tokens_null_jwt();
    """)

    # One-time scrub of any raw tokens already persisted (small table — session
    # tokens, kept trimmed by the sweep job).
    execute("UPDATE op.guardian_tokens SET jwt = NULL WHERE jwt IS NOT NULL;")
  end

  def down do
    execute("DROP TRIGGER IF EXISTS guardian_tokens_null_jwt_trigger ON op.guardian_tokens;")
    execute("DROP FUNCTION IF EXISTS op.guardian_tokens_null_jwt();")
  end
end
