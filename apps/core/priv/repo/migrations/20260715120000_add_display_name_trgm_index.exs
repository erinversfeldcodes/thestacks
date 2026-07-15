defmodule Core.Repo.Migrations.AddDisplayNameTrgmIndex do
  @moduledoc """
  GIN trigram index on `lower(op.users.display_name)` so people-search
  (`Stacks.Accounts.search_users/2`) stops sequentially scanning `op.users`.

  A leading-wildcard `ILIKE '%term%'` cannot use a btree index, so each search
  scanned the whole table (Issue #222). `pg_trgm`'s `gin_trgm_ops` operator class
  supports `LIKE`/`ILIKE`, letting the planner satisfy
  `lower(display_name) ILIKE '%term%'` from this index. The query in
  `search_users/2` was reshaped to compare against `lower(display_name)` so the
  expression matches the indexed expression.

  Built `CONCURRENTLY` so it never takes a write-blocking lock on `op.users`
  (an auth/profile hot-path table), which — like the handle index in
  `20260714200520` — requires `@disable_ddl_transaction` /
  `@disable_migration_lock` (a concurrent build cannot run inside a transaction).

  Extension privilege: `CREATE EXTENSION IF NOT EXISTS pg_trgm` needs a role with
  the CREATE privilege on the database (the same requirement the pgvector
  migration `20260713181722` already relies on, so the local/CI migration role
  has it). It is guarded with `IF NOT EXISTS` and is a no-op when `pg_trgm` is
  already installed. If a deploy environment's app role lacks that privilege, a
  DBA must `CREATE EXTENSION pg_trgm;` once out-of-band before this migration
  runs; the index build itself needs no extension privilege.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

    create index(:users, ["lower(display_name) gin_trgm_ops"],
             prefix: "op",
             name: :users_display_name_trgm_index,
             using: "gin",
             concurrently: true
           )
  end

  def down do
    drop_if_exists index(:users, ["lower(display_name) gin_trgm_ops"],
                     prefix: "op",
                     name: :users_display_name_trgm_index,
                     concurrently: true
                   )
  end
end
