defmodule Core.Repo.Migrations.IndexThePlacementOwnerConcurrently do
  use Ecto.Migration

  # Both flags, deliberately. CREATE INDEX CONCURRENTLY cannot run inside a
  # transaction, so @disable_ddl_transaction is required; and Ecto's own
  # advisory migration lock is itself a transaction, so without
  # @disable_migration_lock the CONCURRENTLY build still runs inside one and
  # fails. Omitting the second flag is the trap a sibling index migration fell
  # into — present here so it is fixed rather than repeated.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create index(:bookshelf_placements, [:user_id],
             prefix: "op",
             concurrently: true,
             name: "bookshelf_placements_user_id_idx"
           )
  end

  def down do
    drop index(:bookshelf_placements, [:user_id],
           prefix: "op",
           concurrently: true,
           name: "bookshelf_placements_user_id_idx"
         )
  end
end
