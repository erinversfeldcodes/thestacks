defmodule Core.Repo.Migrations.EncryptAuditLogMetadata do
  use Ecto.Migration

  # ⚠️ Attested retrospectively on 2026-10-16, when `lint-migrations.sh` learned
  # to see `ALTER COLUMN ... TYPE`. This migration shipped long before the rule
  # existed; the attestation records why it was safe, not a new decision.
  @breaking_ok "Converts audit.audit_log.metadata from jsonb to bytea for Cloak " <>
                 "encryption, deliberately discarding the old values with `USING NULL` — " <>
                 "the plaintext cannot be carried into the encrypted column and the audit " <>
                 "trail's other fields (action, resource_type, occurred_at, the IP digest) " <>
                 "are untouched. The expand phase is the Cloak type itself: nothing reads " <>
                 "metadata as jsonb after this point."

  def up do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'staging') THEN
        DROP VIEW IF EXISTS staging.stg_audit_log;
      END IF;
    END $$
    """)

    execute("""
    ALTER TABLE audit.audit_log
      ALTER COLUMN metadata TYPE bytea
      USING NULL
    """)

    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'staging') THEN
        CREATE OR REPLACE VIEW staging.stg_audit_log AS
          SELECT id, user_id, action, resource_type, resource_id,
                 metadata, ip_address, occurred_at
          FROM audit.audit_log;
      END IF;
    END $$
    """)
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'staging') THEN
        DROP VIEW IF EXISTS staging.stg_audit_log;
      END IF;
    END $$
    """)

    execute("""
    ALTER TABLE audit.audit_log
      ALTER COLUMN metadata TYPE jsonb
      USING NULL
    """)

    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'staging') THEN
        CREATE OR REPLACE VIEW staging.stg_audit_log AS
          SELECT id, user_id, action, resource_type, resource_id,
                 metadata, ip_address, occurred_at
          FROM audit.audit_log;
      END IF;
    END $$
    """)
  end
end
