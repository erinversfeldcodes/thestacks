defmodule Core.Repo.Migrations.CreateAuthTokenFamilies do
  @moduledoc """
  Refresh-token family / session tracking (Issue #179, Phase 2a).

  Every login opens a *family*: a rotation chain identified by a stable
  `family_id` that is carried forward (as a JWT claim) across every refresh
  rotation. The family row records the family's current live access token
  (`current_jti`) so a later phase (2b) can detect reuse of a superseded token
  and revoke the whole family.

  This table is hand-migrated (NOT proto-generated) — it holds server-side
  auth session state, not a domain entity, so it has no `.proto` contract and
  `mix proto.sync` neither generates nor drifts against it. It uses the
  project's standard `timestamps()` (globally rewritten to `created_at` /
  `updated_at` at microsecond precision — see config/config.exs), so unlike
  op.guardian_tokens (which mirrors Guardian.DB's `inserted_at` schema and
  therefore declares its timestamps explicitly) this table keeps the default.

  `family_id` is supplied by the application (login generates it via
  `Ecto.UUID.generate/0`) rather than a DB default, because the same value must
  be embedded in the JWT before the row is written.
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
