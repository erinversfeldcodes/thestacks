defmodule Core.Repo.Migrations.CreateGuardianTokens do
  @moduledoc """
  Server-side JWT tracking for revocation (Issue #124, A2).

  Backs `Guardian.DB` so `Guardian.revoke/1` (and logout) actually invalidate a
  token: every issued "access" token is stored here on sign, presence-checked on
  every verify, and deleted on revoke.

  The column shape matches `Guardian.DB.Token`'s Ecto schema exactly:
  a string `jti` primary key and default `timestamps()` (naive_datetime named
  inserted_at/updated_at). We therefore add the timestamp columns explicitly
  rather than via the `timestamps()` macro, which this project globally rewrites
  to `created_at` (see config/config.exs) — a name Guardian.DB's schema does not
  expect.
  """

  use Ecto.Migration

  def up do
    create table(:guardian_tokens, prefix: "op", primary_key: false) do
      add :jti, :string, primary_key: true
      add :aud, :string
      add :typ, :string
      add :iss, :string
      add :sub, :string
      add :exp, :bigint
      add :jwt, :text
      add :claims, :map
      add :inserted_at, :naive_datetime, null: false
      add :updated_at, :naive_datetime, null: false
    end

    # sub is the user id; sweeping/revoke-all queries filter on it.
    create index(:guardian_tokens, [:sub], prefix: "op")

    # The token reaper (GuardianTokenSweepJob) deletes WHERE exp < now(); index
    # exp so that range delete uses an index scan instead of a seq scan as the
    # table grows.
    create index(:guardian_tokens, [:exp], prefix: "op")

    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_app') THEN
        GRANT INSERT, SELECT, UPDATE, DELETE ON op.guardian_tokens TO stacks_app;
      END IF;
    END $$;
    """)

    # stacks_dbt is intentionally NOT granted access: raw JWTs and their claims
    # have no analytics use and tracking them in the warehouse would widen the
    # blast radius of a warehouse-credential compromise.
  end

  def down do
    drop table(:guardian_tokens, prefix: "op")
  end
end
