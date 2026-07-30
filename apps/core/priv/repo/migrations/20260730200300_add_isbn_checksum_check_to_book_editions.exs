defmodule Core.Repo.Migrations.AddIsbnChecksumCheckToBookEditions do
  @moduledoc """
  The ISBN hard gate, as a database fact (Issue #335 D4).

  "No book enters the system without a verified ISBN" is enforced twice in
  application code — `Books.book_edition_changeset/2`'s `validate_format` +
  `validate_isbn_checksum/1`, and `Books.valid_isbn_checksum?/1` on the
  moderation fast path — and nowhere else. Every writer that does not go through
  a changeset (a seed script, `psql`, a future bulk importer, a test factory)
  can put a string that is not an ISBN into `op.book_editions.isbn`, and nothing
  notices until a downstream lookup silently returns nothing.

  The constraint restates the EAN-13 rule the changeset applies: thirteen
  digits, whose digits weighted 1,3,1,3,… sum to a multiple of ten. Thirteen —
  not "ten or thirteen" — because `Books.book_edition_changeset/2` normalises
  every accepted ISBN-10 to its ISBN-13 form (`normalize_edition_isbn/1`) before
  it is ever stored, so a stored ten-digit ISBN would itself be a defect.

  Written as an inline expression rather than a helper function on purpose: a
  CHECK that calls a user-defined function silently stops meaning what it said
  the day someone replaces the function, and `pg_dump`/restore has to get the
  ordering right. The expression cannot drift.

  Added `NOT VALID` here and validated by `20260730200350`, which runs OUTSIDE a
  transaction so the ACCESS EXCLUSIVE window excludes the scan (squawk
  `constraint-missing-not-valid`). If validation fails, a row in
  `op.book_editions` is not an ISBN — that is a defect to look at, not a
  migration to weaken.

  NULL `isbn` is untouched by the CHECK (SQL three-valued logic); the column's
  own `NOT NULL` from `20260318065431` already forbids it.
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
