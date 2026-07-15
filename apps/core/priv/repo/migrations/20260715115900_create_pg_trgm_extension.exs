defmodule Core.Repo.Migrations.CreatePgTrgmExtension do
  @moduledoc """
  Enable the `pg_trgm` extension in its OWN migration, ahead of the concurrent
  trigram index build in `20260715120000`.

  Why split from the index migration: `pg_trgm` + a `CREATE INDEX CONCURRENTLY`
  in the same file makes the extracted SQL two statements, and the squawk gate
  (`scripts/security-squawk.sh`, run with `--assume-in-transaction`) then flags
  the concurrent index as being created inside a transaction. A concurrent index
  must be the migration's only statement to be recognised as auto-committing, so
  the extension lives here instead.

  `CREATE EXTENSION IF NOT EXISTS` is idempotent (no-op when already installed).
  Needs a role with the CREATE privilege on the database — the same requirement
  the pgvector migration `20260713181722` already relies on. If a deploy
  environment's app role lacks it, a DBA must `CREATE EXTENSION pg_trgm;` once
  out-of-band before this runs.
  """
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")
  end

  # No-op down: dropping a shared extension could break other objects that depend
  # on it, and the extension is harmless when left installed.
  def down do
    :ok
  end
end
