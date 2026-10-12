defmodule Core.Repo.Migrations.ConstrainUsersAuthStateConsistency do
  @moduledoc """
      Two auth invariants that until now lived only in `Stacks.Email` and
      `Stacks.Accounts`, restated as database facts so a writer that bypasses
      them — psql, a seed, a bulk repair, a future context — cannot leave an
      account in a state the readers of these columns do not handle.

      ## `users_password_reset_pair_consistent`

          (password_reset_token IS NULL) = (password_reset_sent_at IS NULL)

      The token and the time it was issued are one fact in two columns. Both
      writers set them together: `Stacks.Email.do_send_password_reset/1` stores
      the pair, `do_reset_password/2` nulls the pair when the reset is spent.
      A half-set pair is either a live reset link nobody can age out, or an
      issue time pointing at no link.

      ## `users_login_lockout_state_consistent`

      The lockout trio is written by exactly three statements in
      `Stacks.Accounts`, and between them they hold:

        1. `failed_login_count >= 0` — it is a count of attempts.

        2. `(failed_login_count = 0) = (failed_login_first_at IS NULL)` — the
           counter and the start of the window it accumulated in are one fact.
           `record_failed_login/2` never sets a count without the window start
           (`next_failure_window/3` returns both), and `clear_failed_logins/2`
           is the only thing that zeroes the count, nulling the start in the
           same statement.

        3. `locked_until IS NOT NULL` implies `failed_login_count > 0` — a lock
           is only ever set by a failure that reached the threshold, and the
           only statement that zeroes the count also clears the lock. This is
           an implication rather than an equivalence on purpose: an expired
           `locked_until` legitimately outlives the window that produced it,
           because a failure arriving after the window rolls the count back to
           1 (not 0) and leaves the old expiry in place for the backoff
           calculation to read.

      Both are added `NOT VALID` — no full-table scan under an ACCESS EXCLUSIVE
      lock — and validated in the following migration, which runs in its own
      transaction so `VALIDATE CONSTRAINT` takes only SHARE UPDATE EXCLUSIVE.

      The repairs below run first so that validation cannot fail on history.
      Neither should match a row: every code path that has ever written these
      columns already satisfies the invariants. They exist because `NOT VALID`
      followed by a `VALIDATE` that errors is an outage, and "should not match"
      is not a thing to find out during a deploy.

      A violating reset pair is cleared rather than completed: the surviving
      half cannot tell us the missing half, and the cost of clearing is that one
      reader requests a new link, against the cost of keeping a reset link with
      an unknowable age. Likewise a violating lockout trio is returned to the
      clean no-failures state — it is the state a successful login would
      produce, and the lock it releases is a minutes-to-hours speed bump whose
      justifying history is, by definition of the violation, not reconstructable.
  """
  use Ecto.Migration

  def up do
    execute("""
    UPDATE op.users
       SET password_reset_token = NULL,
           password_reset_sent_at = NULL
     WHERE (password_reset_token IS NULL) <> (password_reset_sent_at IS NULL)
    """)

    execute("""
    UPDATE op.users
       SET failed_login_count = 0,
           failed_login_first_at = NULL,
           locked_until = NULL
     WHERE (failed_login_count = 0) <> (failed_login_first_at IS NULL)
        OR (locked_until IS NOT NULL AND failed_login_count = 0)
        OR failed_login_count < 0
    """)

    execute("""
    ALTER TABLE op.users
      ADD CONSTRAINT users_password_reset_pair_consistent
      CHECK ((password_reset_token IS NULL) = (password_reset_sent_at IS NULL))
      NOT VALID
    """)

    execute("""
    ALTER TABLE op.users
      ADD CONSTRAINT users_login_lockout_state_consistent
      CHECK (
        failed_login_count >= 0
        AND (failed_login_count = 0) = (failed_login_first_at IS NULL)
        AND (locked_until IS NULL OR failed_login_count > 0)
      )
      NOT VALID
    """)
  end

  def down do
    execute("""
    ALTER TABLE op.users DROP CONSTRAINT IF EXISTS users_login_lockout_state_consistent
    """)

    execute("""
    ALTER TABLE op.users DROP CONSTRAINT IF EXISTS users_password_reset_pair_consistent
    """)
  end
end
