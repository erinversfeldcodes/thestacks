defmodule Core.Repo.Migrations.LetAnAssociationGoUnscoredAndTheLogSayAmbiguous do
  @moduledoc """
      Two small catalog changes for the structured-decoding follow-ons.

      `op.post_book_associations.confidence` becomes NULLABLE: an association the
      model returned WITHOUT rating it is now nil, distinct from a scored 0.0. A
      NOT NULL column forced the decoder to default a missing confidence to 0.0,
      which rendered an unscored match as a confident "0% low" badge. The range
      CHECK ([0,1]) is unaffected — a CHECK passes on NULL.

      `op.llm_call_log.outcome_is_known` gains `'ambiguous'`: a response carrying
      TWO fenced blocks that both parse is two answers, and the decoder now names
      that `:ambiguous` rather than guessing. The widened constraint is added
      `NOT VALID` here (a brief catalog lock, no scan) and VALIDATEd out of a
      transaction by the sibling migration, so the scan never holds ACCESS
      EXCLUSIVE on a populated log.
  """
  use Ecto.Migration

  @outcomes_with_ambiguous "outcome IN ('associated', 'no_books_found', 'unreadable_response', 'unexpected_shape', 'llm_error', 'ambiguous')"
  @outcomes_without "outcome IN ('associated', 'no_books_found', 'unreadable_response', 'unexpected_shape', 'llm_error')"

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    execute("""
    -- squawk-ignore ban-drop-not-null
    ALTER TABLE op.post_book_associations ALTER COLUMN confidence DROP NOT NULL
    """)

    drop constraint(:llm_call_log, :outcome_is_known, prefix: "op")

    create constraint(:llm_call_log, :outcome_is_known,
             check: @outcomes_with_ambiguous,
             prefix: "op",
             validate: false
           )
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    drop constraint(:llm_call_log, :outcome_is_known, prefix: "op")

    create constraint(:llm_call_log, :outcome_is_known,
             check: @outcomes_without,
             prefix: "op"
           )

    execute("ALTER TABLE op.post_book_associations ALTER COLUMN confidence SET NOT NULL")
  end
end
