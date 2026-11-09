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

  def up do
    # Collapse any existing duplicates before the index can refuse them. Keeps
    # the highest-confidence row, which is the one `list_associations/1` orders
    # first and therefore the one a reader has been seeing.
    execute """
    DELETE FROM op.post_book_associations a
     USING op.post_book_associations b
     WHERE a.post_id = b.post_id
       AND a.book_id = b.book_id
       AND (a.confidence, a.id) < (b.confidence, b.id)
    """

    create unique_index(:post_book_associations, [:post_id, :book_id], prefix: "op")
  end

  def down do
    drop unique_index(:post_book_associations, [:post_id, :book_id], prefix: "op")
  end
end
