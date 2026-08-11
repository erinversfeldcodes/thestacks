defmodule Core.Repo.Migrations.CreateGuardianTokens do
  @moduledoc """
    Server-side JWT tracking for revocation.

    Backs `Guardian.DB` so `Guardian.revoke/1` (and logout) actually invalidate a
    token: every issued "access" token is stored here on sign, presence-checked on
    every verify, and deleted on revoke.

    The column shape matches `Guardian.DB.Token`'s Ecto schema exactly:
    a string `jti` primary key and default `timestamps` (naive_datetime named
    inserted_at/updated_at). We therefore add the timestamp columns explicitly
    rather than via the `timestamps` macro, which this project globally rewrites
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

    create index(:guardian_tokens, [:sub], prefix: "op")

    create index(:guardian_tokens, [:exp], prefix: "op")

    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_app') THEN
        GRANT INSERT, SELECT, UPDATE, DELETE ON op.guardian_tokens TO stacks_app;
      END IF;
    END $$;
    """)
  end

  def down do
    drop table(:guardian_tokens, prefix: "op")
  end
end
