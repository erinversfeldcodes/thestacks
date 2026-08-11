defmodule Core.Repo.Migrations.AddIsbnChecksumCheckToBookEditions do
  @moduledoc """
    The ISBN hard gate as a database fact: a CHECK restating the
    changeset's EAN-13 rule (13 digits, weighted checksum), so writers that
    bypass changesets — seeds, psql, bulk importers, factories — can no
    longer store a non-ISBN. Added `NOT VALID` (no full-table scan under an
    ACCESS EXCLUSIVE lock); validated in `20260730200350` after the two
    data repairs land.
  """
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE op.book_editions
      ADD CONSTRAINT book_editions_isbn_ean13_checksum
      CHECK (
        isbn ~ '^[0-9]{13}$'
        AND (
          (
            substr(isbn, 1, 1)::int + substr(isbn, 3, 1)::int + substr(isbn, 5, 1)::int
            + substr(isbn, 7, 1)::int + substr(isbn, 9, 1)::int + substr(isbn, 11, 1)::int
            + substr(isbn, 13, 1)::int
          )
          + 3 * (
            substr(isbn, 2, 1)::int + substr(isbn, 4, 1)::int + substr(isbn, 6, 1)::int
            + substr(isbn, 8, 1)::int + substr(isbn, 10, 1)::int + substr(isbn, 12, 1)::int
          )
        ) % 10 = 0
      ) NOT VALID
    """)
  end

  def down do
    execute("""
    ALTER TABLE op.book_editions DROP CONSTRAINT IF EXISTS book_editions_isbn_ean13_checksum
    """)
  end
end
