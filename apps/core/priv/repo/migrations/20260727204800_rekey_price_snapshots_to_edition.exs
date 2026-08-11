defmodule Core.Repo.Migrations.RekeyPriceSnapshotsToEdition do
  use Ecto.Migration

  @moduledoc """
  Re-key `op.price_snapshots` from the work to the edition.

  A price is a fact about an *edition*, not a work: shops stock whichever
  edition they stock, at different prices. Exclusive Books carries six ISBNs of
  The Name of the Rose — two of them Spanish — at prices from R400 to R411.

  Keying uniqueness on `(book_id, store_id)` had a concrete consequence beyond
  untidiness: because `Prices.stale_isbns/1` left-joined editions to snapshots on
  `book_id`, pricing **one** edition marked **every** edition of that work as
  freshly scraped, so the other five could never be priced at all.

  `mix proto.sync` adds the column itself (it emits a bare `:binary_id`), so
  this migration supplies what the generator does not: the foreign key, and the
  index swap. Run when the table is empty — hence the safety guard below rather
  than a backfill.

  ## Ordering dependency — keep this migration after the generated one

  This migration `modify`s a column it does not create, so
  `20260727204630_add_book_edition_id_to_price_snapshots.exs` **must** sort
  before it. `mix proto.sync` stamps generated migrations with the current time,
  so regenerating that file lands it *after* this one and a fresh database then
  fails on a column that does not exist yet. If it is ever regenerated, rename it
  back into the 204630 slot rather than leaving the new timestamp.
  """

  def up do
    execute("""
    DO $$
    DECLARE n bigint;
    BEGIN
      SELECT count(*) INTO n FROM op.price_snapshots;
      IF n > 0 THEN
        RAISE EXCEPTION
          'op.price_snapshots has % row(s); re-keying to book_edition_id needs a designed backfill, not this migration', n;
      END IF;
    END $$;
    """)

    alter table(:price_snapshots, prefix: "op") do
      modify :book_edition_id,
             references(:book_editions, type: :binary_id, prefix: "op", on_delete: :delete_all),
             from: :binary_id
    end
  end

  def down do
    alter table(:price_snapshots, prefix: "op") do
      modify :book_edition_id, :binary_id,
        from: references(:book_editions, type: :binary_id, prefix: "op")
    end
  end
end
