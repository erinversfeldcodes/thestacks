defmodule Core.Repo.Migrations.LetAPassThatFoundNothingSaySo do
  @moduledoc """
      Add `no_books_found` to the association outcome vocabulary.

      ⛔ A PASS THAT FOUND NOTHING WAS INDISTINGUISHABLE FROM ONE THAT FOUND
      BOOKS. `persist_associations/2` recorded `:associated` either way, so
      neither the dashboard nor the author could tell a working pass over a post
      with no books in it from a pass that linked three.

      ⚖️ The author-facing difference is the point: "no books from your shelves
      came up in this post" is a result, while silence is a question. The copy
      needed an outcome behind it, and there was none.

      ⚠️ It is a SUCCESS, not a failure — the pass ran and the model answered.
      Grouping it with the error outcomes would make a healthy post look like a
      broken one on the panel.
  """
  use Ecto.Migration

  def up do
    drop constraint(:llm_call_log, :outcome_is_known, prefix: "op")

    create constraint(:llm_call_log, :outcome_is_known,
             check:
               "outcome IN ('associated', 'no_books_found', 'unreadable_response', " <>
                 "'unexpected_shape', 'llm_error')",
             prefix: "op"
           )
  end

  def down do
    # ⚠️ Rows holding the new value would violate the narrower constraint, so
    # they are folded back into the label they used to carry rather than left to
    # fail the migration. Lossy by necessity, and in the direction that keeps
    # the old meaning true: these were passes that completed.
    execute "UPDATE op.llm_call_log SET outcome = 'associated' WHERE outcome = 'no_books_found'"

    drop constraint(:llm_call_log, :outcome_is_known, prefix: "op")

    create constraint(:llm_call_log, :outcome_is_known,
             check:
               "outcome IN ('associated', 'unreadable_response', 'unexpected_shape', 'llm_error')",
             prefix: "op"
           )
  end
end
