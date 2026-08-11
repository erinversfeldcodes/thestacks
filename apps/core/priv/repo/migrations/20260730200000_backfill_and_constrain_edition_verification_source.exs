defmodule Core.Repo.Migrations.BackfillAndConstrainEditionVerificationSource do
  @moduledoc """
    Companion to the proto-generated `add:verification_source`:
    backfills every edition, tightens to NOT NULL, pins the domain with a
    CHECK. The column makes "was this ISBN externally verified?" a recorded
    fact — previously only inferable from the placeholder title, and lost
    the moment `EnrichBookJob` replaced it. Backfill maps provider ids →
    their source, falling back to `barcode_unverified` for rows of unknown
    origin (the honest reading; see the 370 correction for seed rows).
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
