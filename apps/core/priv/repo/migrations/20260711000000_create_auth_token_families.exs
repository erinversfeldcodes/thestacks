defmodule Core.Repo.Migrations.CreateAuthTokenFamilies do
  @moduledoc """
      Refresh-token family / session tracking. Every login
      opens a family: a rotation chain under a stable `family_id` (JWT claim),
      recording the live token (`current_jti`) so reuse of a superseded token
      can burn the family. Hand-migrated, NOT proto-generated: server-side
      auth state, no `.proto` contract, invisible to `mix proto.sync`.
  """

  use Ecto.Migration

  def up do
    create table(:auth_token_families, prefix: "op", primary_key: false) do
      add :family_id, :uuid, primary_key: true
      add :user_id, :uuid, null: false
      add :current_jti, :text, null: false
      add :session_started_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec

      timestamps()
    end

    create index(:auth_token_families, [:user_id], prefix: "op")

    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_app') THEN
        GRANT INSERT, SELECT, UPDATE, DELETE ON op.auth_token_families TO stacks_app;
      END IF;
    END $$;
    """)
  end

  def down do
    drop table(:auth_token_families, prefix: "op")
  end
end
