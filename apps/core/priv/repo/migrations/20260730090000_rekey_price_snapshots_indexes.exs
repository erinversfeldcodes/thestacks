defmodule Core.Repo.Migrations.RekeyPriceSnapshotsIndexes do
  use Ecto.Migration

  @moduledoc """
    The index half of the price-snapshots rekey (see
    `20260727204800_rekey_price_snapshots_to_edition.exs`), split out so the
    indexes can be built CONCURRENTLY per the house migration standard —
    squawk's require-concurrent-index-creation gate, which the combined
    transactional migration could not satisfy.

    Idempotent (`*_if_not_exists` / `drop_if_exists`): staging and previews
    that already ran the pre-split rekey have these indexes; fresh databases
    get them here. The new unique index is created BEFORE the old grain is
    dropped so uniqueness never lapses.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists index(:price_snapshots, [:book_edition_id],
                           prefix: "op",
                           concurrently: true
                         )

    create_if_not_exists unique_index(:price_snapshots, [:book_edition_id, :store_id],
                           prefix: "op",
                           concurrently: true
                         )

    drop_if_exists unique_index(:price_snapshots, [:book_id, :store_id],
                     prefix: "op",
                     concurrently: true
                   )
  end

  def down do
    create_if_not_exists unique_index(:price_snapshots, [:book_id, :store_id],
                           prefix: "op",
                           concurrently: true
                         )

    drop_if_exists unique_index(:price_snapshots, [:book_edition_id, :store_id],
                     prefix: "op",
                     concurrently: true
                   )

    drop_if_exists index(:price_snapshots, [:book_edition_id],
                     prefix: "op",
                     concurrently: true
                   )
  end
end
