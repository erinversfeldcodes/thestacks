defmodule Core.Repo.Migrations.BackfillPlacementBookEditionId do
  @moduledoc """
    Companion to the proto-generated `add:book_edition_id`:
    points every placement at its work's primary edition. Placements only
    ever recorded the WORK; "I own the hardback" had nowhere to live except
    `formats` (kept — read paths still use it). Stays NULLABLE with
    `ON DELETE SET NULL`: the edition is not the placement's identity,
    `book_id` is.
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
