defmodule Core.Repo.Migrations.ConstrainUsersPendingEmailState do
  @moduledoc """
      The pending email-change quartet is one fact in four columns, restated as a
      database fact so a writer that bypasses the context — psql, a seed, a bulk
      repair, a future flow — cannot leave an account in a state the readers of
      these columns do not handle.

          (pending_email IS NULL) = (pending_email_token IS NULL)
          (pending_email IS NULL) = (pending_email_sent_at IS NULL)
          (pending_email IS NULL) = (pending_email_revert_token IS NULL)

      Every writer sets or clears all four together: the change request stores the
      address, both tokens and the request time in one changeset; confirming swaps
      the address in and nulls the quartet; reverting nulls it. Each half-set shape
      is its own broken account — an address waiting on a link that does not exist,
      a live link resolving to no address, or a change with no clock, which the
      window sweep can never age out and which therefore degrades nothing, ever.

      Added `NOT VALID` and validated in the following migration, which runs in its
      own transaction so `VALIDATE CONSTRAINT` takes SHARE UPDATE EXCLUSIVE rather
      than holding ACCESS EXCLUSIVE across a full scan. The columns are new and
      every row holds four NULLs today, so there is nothing to repair first — but
      the pair is what the table's other invariants use, and a constraint added the
      cheap way here would be the one that reads differently in six months.
  """
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE op.users
      ADD CONSTRAINT users_pending_email_state_consistent
      CHECK (
        (pending_email IS NULL) = (pending_email_token IS NULL)
        AND (pending_email IS NULL) = (pending_email_sent_at IS NULL)
        AND (pending_email IS NULL) = (pending_email_revert_token IS NULL)
      )
      NOT VALID
    """)
  end

  def down do
    execute("""
    ALTER TABLE op.users DROP CONSTRAINT IF EXISTS users_pending_email_state_consistent
    """)
  end
end
