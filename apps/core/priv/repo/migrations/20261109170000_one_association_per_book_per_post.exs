defmodule Core.Repo.Migrations.OneAssociationPerBookPerPost do
  @moduledoc """
      One association per book per post.

      ⛔ A MODEL REPEATING A TITLE GAVE THE READER TWO IDENTICAL ASSOCIATIONS.
      `op.post_book_associations` had an index on `post_id` and no uniqueness,
      and `Blog.associate_book/3` inserts unconditionally — so a response naming
      the same `book_id` twice produced two rows. Measured: the second insert
      returns `:ok` and `list_associations/1` then returns 2.

      ⚖️ The LLM path makes this likely rather than exotic: a model asked about
      a post that discusses one book in two registers will name it twice, and
      the association corpus has a fixture for exactly that. The corpus's note
      said "a reader's shelf must not gain a duplicate because the model said a
      title twice" — which was a statement about what *should* happen, scored
      against an eval that de-duplicated in its own code while production did
      not.

      ⚠️ Deliberately NOT keyed on `visible`. A dismissed association and a
      suggested one for the same book are the same association in two states,
      not two associations — re-suggesting a book the reader has already
      dismissed should update or be refused, never appear beside it.
  """
  use Ecto.Migration

  # ⚖️ THE DELETE ONLY. The unique index that enforces this invariant lives in the
  # next migration, because it must be built CONCURRENTLY on a table that has
  # rows — and `concurrently: true` cannot run inside a transaction, which is
  # the only place `SET LOCAL` has any effect. Rather than waive one of the two
  # safety rules, each statement sits in the migration whose transaction
  # semantics suit it: this one collapses duplicates under timeouts, the next
  # builds the index without blocking writes.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    # Collapse any existing duplicates before the index can refuse them.
    #
    # ⛔ THE TIE-BREAK USED TO BE A RANDOM UUID. The old spelling compared
    # `(a.confidence, a.id) < (b.confidence, b.id)`, so on equal confidence the
    # survivor was decided by v4 random bytes — measured: the visible, newer row
    # was deleted and a dismissed, older one survived. The comment claimed the
    # survivor was "the one a reader has been seeing", a determinism that
    # existed in neither this DELETE nor `list_associations/1`.
    #
    # ⚠️ And the confidence clamp landing the same day made ties the NORMAL
    # case rather than a rare one: `Structured.clamp/1` maps every out-of-range
    # value to exactly `1.0`, so a model answering `1.4` and `2.5` for one book
    # now produces an exact tie. A normalisation that maps many inputs to one
    # value raises collisions in every tie-break below it, by construction.
    #
    # ⚖️ `visible DESC` is a product decision and this is where it is recorded:
    # a live suggestion beats a dismissal. A dismissal is a judgement about THAT
    # suggestion, and these rows are competing representations of one
    # `(post_id, book_id)` fact rather than two suggestions the author ruled on
    # separately — so keeping the dismissed row would apply a judgement the
    # author made about one row to a row they never saw. The opposite error,
    # resurfacing something they dismissed, is visible and one click to undo;
    # this one is invisible and permanent.
    execute """
    DELETE FROM op.post_book_associations
     WHERE id NOT IN (
       SELECT DISTINCT ON (post_id, book_id) id
         FROM op.post_book_associations
        ORDER BY post_id, book_id, confidence DESC, visible DESC, created_at DESC, id
     )
    """
  end

  # ⚠️ Deliberately empty: a collapsed duplicate cannot be reconstructed, and
  # inventing a second row to restore symmetry would be worse than admitting the
  # deletion was one-way. The index's own migration rolls back cleanly.
  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    :ok
  end
end
