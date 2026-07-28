defmodule Core.Repo.Migrations.AddGeoIndexesToThirdSpacesAndBookstores do
  @moduledoc """
  Adds the bounding-box indexes for the third-spaces map (US-3.1.1).

  The map's primary query is a viewport, which *is* a bounding box, so both
  coordinates are range predicates: `latitude between ? and ? and longitude
  between ? and ?`. Latitude leads because it is the more selective of the two at
  the zoom levels the page uses.

  Bookshops get the same index because the 500 m rule pairs a space with a shop —
  the geocoding pass scans bookstores by bounding box to find each space's nearest
  one.

  Hand-written rather than proto-generated: `proto/persisted.exs` declares these
  indexes (so the contract records them and a fresh database gets them at table
  creation), but both tables carry `migration_exists: true`, so `mix proto.sync`
  emits column migrations only. This applies the same indexes to already-created
  databases.

  `CREATE INDEX CONCURRENTLY` cannot run inside a transaction, hence
  `@disable_ddl_transaction` / `@disable_migration_lock`, matching the sibling
  concurrent-index migrations. Concurrent is strictly unnecessary today — both
  tables are small and `op.third_spaces` is empty — but it costs nothing here and
  means this migration stays safe if it is ever replayed against a populated
  database.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists index(:third_spaces, [:latitude, :longitude],
                           prefix: "op",
                           name: "idx_third_spaces_lat_lng",
                           concurrently: true
                         )

    create_if_not_exists index(:bookstores, [:latitude, :longitude],
                           prefix: "op",
                           name: "idx_bookstores_lat_lng",
                           concurrently: true
                         )
  end

  def down do
    drop_if_exists index(:third_spaces, [:latitude, :longitude],
                     prefix: "op",
                     name: "idx_third_spaces_lat_lng",
                     concurrently: true
                   )

    drop_if_exists index(:bookstores, [:latitude, :longitude],
                     prefix: "op",
                     name: "idx_bookstores_lat_lng",
                     concurrently: true
                   )
  end
end
