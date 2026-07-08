defmodule Core.Repo.Migrations.CreateAdminSessions do
  use Ecto.Migration

  def up do
    create table(:admin_sessions, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :user_id,
          references(:users, type: :binary_id, prefix: "op", on_delete: :delete_all),
          null: false

      add :ip_hash, :text, null: false
      add :boot_id, :text, null: false
      add :mfa_verified_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create index(:admin_sessions, [:user_id], prefix: "op")
    create index(:admin_sessions, [:expires_at], prefix: "op")

    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_app') THEN
        GRANT INSERT, SELECT, UPDATE ON op.admin_sessions TO stacks_app;
      END IF;
    END $$;
    """)

    execute(
      """
      DO $$ BEGIN
        IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_dbt') THEN
          GRANT SELECT ON op.admin_sessions TO stacks_dbt;
        END IF;
      END $$;
      """,
      """
      DO $$ BEGIN
        IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_dbt') THEN
          REVOKE SELECT ON op.admin_sessions FROM stacks_dbt;
        END IF;
      END $$;
      """
    )
  end

  def down do
    drop table(:admin_sessions, prefix: "op")
  end
end
