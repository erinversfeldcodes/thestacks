defmodule Core.Repo.Migrations.BuildTheLookingForHomeIndexConcurrently do
  use Ecto.Migration

  # The partial index the narrowed looking_for_home policy arm needs: only a
  # handful of shelves ever hold a live listing, so `name = 'looking_for_home'`
  # among them is an Index Scan instead of the 20%-selectivity Seq Scan the broad
  # arm forced. Built CONCURRENTLY in its own migration (both lock flags off) so
  # building it on a populated op.bookshelves never takes the ACCESS EXCLUSIVE
  # lock a plain CREATE INDEX would. Split out of the narrowing migration because
  # that one is transactional (policy + trigger + backfill + assertion land
  # atomically) and CONCURRENTLY cannot run in a transaction; the narrowed policy
  # is correct without the index, only slower, so the two need not land together.
  # `create_if_not_exists` so a re-run on a stack that already built the index
  # under the previous single-migration shape is a no-op rather than a failure.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("SET lock_timeout = '5s'")
    execute("SET statement_timeout = 0")

    create_if_not_exists index(:bookshelves, [:name],
                           prefix: "op",
                           concurrently: true,
                           name: :bookshelves_looking_for_home_active_idx,
                           where: "active_listing_count > 0"
                         )
  end

  def down do
    execute("SET lock_timeout = '5s'")
    execute("SET statement_timeout = 0")

    drop_if_exists index(:bookshelves, [:name],
                     prefix: "op",
                     concurrently: true,
                     name: :bookshelves_looking_for_home_active_idx
                   )
  end
end
