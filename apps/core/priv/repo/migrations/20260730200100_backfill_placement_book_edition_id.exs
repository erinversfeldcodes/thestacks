defmodule Core.Repo.Migrations.BackfillPlacementBookEditionId do
  @moduledoc """
  Companion to the proto-generated `add :book_edition_id` migration
  (`20260730193135`, Issue #335 D2). Points every existing placement at the
  primary edition of the work it holds.

  A placement has always recorded *which work* a user shelved, never *which
  edition* — so "I own the hardback but want the ebook" had nowhere to live
  except the `formats` string array, which cannot distinguish two ISBNs of the
  same work. `formats` is deliberately KEPT: retiring it is later work, and
  every existing read path still uses it.

  The column stays NULLABLE. It is not the placement's identity — `book_id`
  is — and its FK is `ON DELETE SET NULL`, so an edition being deleted must be
  able to leave the placement (and therefore the user's reading history)
  standing. Making it NOT NULL would also hand every insert path a new required
  field, which is a behaviour change this migration is not entitled to make.

  Backfill picks `is_primary` — the same edition `Books.primary_edition/1`
  resolves for display — and falls back to the work's oldest edition when no
  edition is flagged primary (possible for legacy rows: the partial unique index
  `book_editions_one_primary_per_book` forbids two primaries but not zero).
  Placements whose work has no edition at all keep NULL.
  """
  use Ecto.Migration

  def up do
    execute("""
    UPDATE op.bookshelf_placements p
    SET book_edition_id = e.id
    FROM (
      SELECT DISTINCT ON (book_id) book_id, id
      FROM op.book_editions
      ORDER BY book_id, is_primary DESC, created_at ASC, id ASC
    ) e
    WHERE e.book_id = p.book_id
      AND p.book_edition_id IS NULL
    """)
  end

  def down do
    execute("UPDATE op.bookshelf_placements SET book_edition_id = NULL")
  end
end
