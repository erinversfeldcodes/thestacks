defmodule Core.Repo.Migrations.EncryptAuditLogMetadata do
  use Ecto.Migration

  # Changes the audit_log.metadata column from jsonb to bytea so that
  # Cloak-encrypted ciphertext can be stored. Stacks.Audit encrypts the
  # metadata map (serialised as JSON) via Stacks.Vault before insertion.
  #
  # Existing rows will have a null metadata value after the migration;
  # they predate encryption and should be treated as redacted.

  def up do
    # The staging.stg_audit_log dbt view depends on this column — drop and recreate it.
    # The staging schema only exists when dbt has been run; guard with DO block.
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
