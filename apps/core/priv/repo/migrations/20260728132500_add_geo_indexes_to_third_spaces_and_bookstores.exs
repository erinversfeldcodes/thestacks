defmodule Core.Repo.Migrations.AddGeoIndexesToThirdSpacesAndBookstores do
  @moduledoc """
  Bounding-box indexes for the third-spaces map (US-3.1.1): the map's
  primary query is a viewport (both coordinates range predicates;
  latitude leads as the more selective). Bookstores get the same index
  for the 500m nearest-shop scan. Hand-written because both tables
  pre-exist: persisted.exs declares the indexes for fresh databases; this
  adds them to existing ones.
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
