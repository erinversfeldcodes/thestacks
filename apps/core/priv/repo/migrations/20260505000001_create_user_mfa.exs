defmodule Core.Repo.Migrations.CreateUserMfa do
  use Ecto.Migration

  def up do
    create table(:user_mfa, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :user_id,
          references(:users, type: :binary_id, prefix: "op", on_delete: :delete_all),
          null: false

      add :totp_secret, :binary, null: false
      add :recovery_codes, {:array, :text}, null: false
      add :enabled_at, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create unique_index(:user_mfa, [:user_id], prefix: "op")

    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_app') THEN
        GRANT INSERT, SELECT, UPDATE ON op.user_mfa TO stacks_app;
      END IF;
    END $$;
    """)

    # stacks_dbt intentionally NOT granted SELECT on op.user_mfa.
    # The totp_secret column stores Cloak-encrypted ciphertext (bytea) and the
    # recovery_codes column stores SHA-256 hashes of sensitive one-time codes.
    # dbt has no legitimate analytics use for this table, so access is withheld
    # to reduce the blast radius of a warehouse credential compromise.
  end

  def down do
    drop table(:user_mfa, prefix: "op")
  end
end
