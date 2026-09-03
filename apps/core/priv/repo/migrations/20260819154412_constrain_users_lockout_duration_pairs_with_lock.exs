defmodule Core.Repo.Migrations.ConstrainUsersLockoutDurationPairsWithLock do
  @moduledoc """
      Extends `users_login_lockout_state_consistent` to cover the fourth
      lockout column, `lockout_duration_seconds`.

      ## Why the column exists

      Each lock is meant to be twice as long as the one before it, up to a cap,
      for as long as the locks keep coming inside the backoff window. That needs
      the length of the previous lock, and the three columns that were here
      could not supply it:

        * `locked_until` is the previous lock's END. Its length is
          `locked_until - (the moment it was applied)`, and the moment it was
          applied is not stored.
        * `failed_login_first_at` cannot stand in for that moment. It is the
          start of the CURRENT rolling failure window, and it moves. A lock
          outlives the window that earned it (the initial lock is longer than
          the window), so the first failure after a lock expires always finds
          the old window start stale and rewrites it to a time AFTER the lock
          ended. By the time the threshold is reached again and the next
          duration is computed, `locked_until - failed_login_first_at` is
          negative.

      The two roles genuinely conflict: the window start must move forward for
      the rolling window to work, and the lock's start must not move for the
      escalation to be readable. One column cannot hold both, so the length is
      persisted directly.

      ## The invariant this adds

          (locked_until IS NULL) = (lockout_duration_seconds IS NULL)
          AND (lockout_duration_seconds IS NULL OR lockout_duration_seconds > 0)

      The expiry and the length are one fact in two columns, the same shape the
      password-reset pair has. `Stacks.Accounts.record_failed_login/2` writes
      both in the statement that applies a lock, and `clear_failed_logins/2`
      nulls both in the statement that releases one. A length of zero or less
      is not a lock anyone was ever held by.

      The three existing conjuncts are restated unchanged, including the
      deliberate implication (rather than equivalence) between `locked_until`
      and `failed_login_count`: an expired lock legitimately outlives the window
      that produced it, and now carries its length with it so the escalation can
      still read it.

      ## Backfill

      Rows already carrying a lock have no recorded length — that absence is the
      defect. It is not reconstructable, so they are seeded with the initial
      duration (`:login_lockout_duration_seconds`, 900s), which makes their next
      lock 1800s. That is exactly what the old derivation produced for them, so
      no account's next lock changes on deploy; escalation past that point is
      what becomes true. The alternative — clearing the locks — would release
      live ones, and a lock nobody has to serve is worse than a lock that
      restarts its ladder.

      The extended CHECK is added `NOT VALID` and validated in the following
      migration, so no full-table scan runs under ACCESS EXCLUSIVE.
  """
  use Ecto.Migration

  def up do
    execute("""
    UPDATE op.users
       SET lockout_duration_seconds = 900
     WHERE locked_until IS NOT NULL
       AND lockout_duration_seconds IS NULL
    """)

    execute("""
    UPDATE op.users
       SET lockout_duration_seconds = NULL
     WHERE locked_until IS NULL
        OR lockout_duration_seconds <= 0
    """)

    execute("ALTER TABLE op.users DROP CONSTRAINT IF EXISTS users_login_lockout_state_consistent")

    execute("""
    ALTER TABLE op.users
      ADD CONSTRAINT users_login_lockout_state_consistent
      CHECK (
        failed_login_count >= 0
        AND (failed_login_count = 0) = (failed_login_first_at IS NULL)
        AND (locked_until IS NULL OR failed_login_count > 0)
        AND (locked_until IS NULL) = (lockout_duration_seconds IS NULL)
        AND (lockout_duration_seconds IS NULL OR lockout_duration_seconds > 0)
      )
      NOT VALID
    """)
  end

  def down do
    execute("ALTER TABLE op.users DROP CONSTRAINT IF EXISTS users_login_lockout_state_consistent")

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
end
