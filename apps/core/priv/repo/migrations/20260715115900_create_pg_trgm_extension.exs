defmodule Core.Repo.Migrations.CreatePgTrgmExtension do
  @moduledoc """
    Enables `pg_trgm` in its OWN migration, ahead of the concurrent index
    in `20260715120000`: a concurrent index must be its migration's only
    statement or squawk (`--assume-in-transaction`) flags it as
    in-transaction. `CREATE EXTENSION IF NOT EXISTS` is idempotent; needs
    CREATE privilege on the database.
  """
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")
  end

  def down do
    :ok
  end
end
