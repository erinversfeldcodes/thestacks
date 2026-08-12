defmodule Core.Repo.Migrations.RekeyPriceSnapshotsToEdition do
  use Ecto.Migration

  @moduledoc """
      Re-keys `op.price_snapshots` from work to edition — a price is a fact
      about an edition (shops stock specific ISBNs at different prices).
      Uniqueness on `(book_id, store_id)` meant pricing ONE edition marked
      every edition of the work freshly scraped, so the rest could never be
      priced. Backfills `book_edition_id` to the work's primary edition,
      re-points uniqueness to `(book_edition_id, store_id)`, keeps `book_id`
      for read-path joins.
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
