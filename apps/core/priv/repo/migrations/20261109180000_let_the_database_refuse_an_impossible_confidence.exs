defmodule Core.Repo.Migrations.LetTheDatabaseRefuseAnImpossibleConfidence do
  @moduledoc """
      Bound both `confidence` columns to [0, 1] at the database.

      ⛔ A CONFIDENCE OF 12.0 WOULD HAVE BEEN STORED AND DISPLAYED. Both columns
      are a bare `:float` with no CHECK, and the association's changeset had no
      `validate_number` either — so the only thing keeping the value in range
      was a clamp inside the JSON parser, three layers from the table.

      ⚖️ Moved to the database because a range invariant is a fact about the
      COLUMN, not about the one path that currently happens to write it. A clamp
      in the parser is correct for the model's answer and says nothing about a
      manual admin override, a backfill, an import, or a second model adapter —
      each of which writes the same column without passing that clamp. The
      reasoning that the clamp is sufficient is a claim about the caller list,
      which changes without anyone revisiting the clamp.

      ⚠️ CLASS, NOT INSTANCE — and the two columns were already inconsistent.
      `op.discovered_sources.confidence` had a changeset `validate_number` and
      `op.post_book_associations.confidence`, added later, did not: the house
      pattern existed and the newer column missed it. Guarding only the new one
      would have left the identical hole in the older one, since neither had
      anything at the database.

      ⬛ THIS MIGRATION ONLY ADDS THE CONSTRAINTS, `NOT VALID`. The scan that
      validates them is its own migration, `…180100` — the shape this repo
      already uses for `…120100` / `…120200`.

      ⚠️ Two earlier versions of this got it wrong and the second is the
      instructive one. First I ran ADD and VALIDATE in one transaction, where
      the split achieves nothing — `squawk`'s `constraint-missing-not-valid`:
      *"Using `NOT VALID` and `VALIDATE CONSTRAINT` in the same transaction will
      block all reads while the constraint is validated."* Then I set
      `@disable_ddl_transaction` and left both statements in this file, and it
      STILL failed, because squawk lints the SQL extracted from the file and
      cannot see an Elixir module attribute. Two statements in one file read as
      one transaction to the linter — and it is right to say so, because nothing
      in the file proves otherwise to a human reader either.

      ⚖️ So the separation has to be real at the file level rather than asserted
      in an attribute. The comment claiming the benefit was the thing to
      distrust, on the same day I wrote a note about descriptions that
      over-claim.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    execute("""
    ALTER TABLE op.post_book_associations
      ADD CONSTRAINT post_book_associations_confidence_in_range
      CHECK (confidence >= 0.0 AND confidence <= 1.0) NOT VALID
    """)

    execute("""
    ALTER TABLE op.discovered_sources
      ADD CONSTRAINT discovered_sources_confidence_in_range
      CHECK (confidence >= 0.0 AND confidence <= 1.0) NOT VALID
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    execute(
      "ALTER TABLE op.post_book_associations DROP CONSTRAINT IF EXISTS post_book_associations_confidence_in_range"
    )

    execute(
      "ALTER TABLE op.discovered_sources DROP CONSTRAINT IF EXISTS discovered_sources_confidence_in_range"
    )
  end
end
