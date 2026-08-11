defmodule Core.Repo.Migrations.BackfillAndConstrainEditionVerificationSource do
  @moduledoc """
  Companion to the proto-generated `add :verification_source` migration
  (`20260730193134`, Issue #335 D1). Backfills every existing edition, tightens
  the column to NOT NULL, and pins the value domain with a CHECK.

  ## Why the column exists

  "Was this ISBN ever verified against an external source?" was previously only
  *inferable*, and only for as long as the inference held: `Stacks.Moderation`'s
  barcode fast path skips the synchronous Open Library / Google Books lookup and
  writes a placeholder work title of `"ISBN <isbn>"`. Once `EnrichBookJob`
  succeeds, that placeholder is replaced and the fact that nothing external ever
  confirmed the ISBN becomes unrecoverable. `verification_source` records it at
  write time instead, on the row that owns the ISBN.

  ## Backfill mapping

      open_library_id IS NOT NULL   -> 'open_library'
      google_books_id IS NOT NULL   -> 'google_books'
      neither                       -> 'barcode_unverified'

  The third bucket is deliberately the conservative reading: it asserts only
  that *no external verification is recorded for this row*, which is exactly
  what a missing identifier tells us. A legacy row that WAS resolved but whose
  resolver never stored an identifier is therefore understated, never
  overstated — an audit of "which ISBNs did we never externally confirm?" may
  return a superset, and can never miss one. `open_library_id` is checked first
  because `Books.create_confirmed_book/4` only ever persists that identifier.
  """
  use Ecto.Migration

  @breaking_ok "verification_source is INTRODUCED by this release (20260730193134). The UPDATE below fills every pre-existing row, and every application write path sets it explicitly: Books.create/1, Books.create_confirmed_book/4 and Books.merge_edition/2 all route through Books.book_edition_changeset/2, which now requires the field. No N-1 code writes op.book_editions at all — Books is the only writer — so no rolling-deploy window can insert a null."

  def up do
    execute("""
    UPDATE op.book_editions
    SET verification_source =
      CASE
        WHEN open_library_id IS NOT NULL AND open_library_id <> '' THEN 'open_library'
        WHEN google_books_id IS NOT NULL AND google_books_id <> '' THEN 'google_books'
        ELSE 'barcode_unverified'
      END
    WHERE verification_source IS NULL
    """)

    alter table(:book_editions, prefix: "op") do
      modify :verification_source, :text, null: false
    end

    create constraint(:book_editions, :book_editions_verification_source_check,
             check:
               "verification_source IN ('open_library', 'google_books', 'barcode_unverified')",
             prefix: "op"
           )
  end

  def down do
    drop_if_exists constraint(:book_editions, :book_editions_verification_source_check,
                     prefix: "op"
                   )

    alter table(:book_editions, prefix: "op") do
      modify :verification_source, :text, null: true
    end
  end
end
