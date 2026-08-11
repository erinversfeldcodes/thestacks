defmodule Core.Repo.Migrations.DowncaseUserEmails do
  @moduledoc """
  Normalises every stored address to lower case, so the case-insensitive unique
  index built in `20260730200500` has nothing to trip over (Issue #335 D4).

  An email address's domain is case-insensitive by definition and no mail
  provider anyone signs up with treats the local part as case-sensitive, but
  `op.users.email` has only ever had an exact-match unique index. Two accounts
  could therefore exist on the same address — and worse, `Accounts.get_user_by_email/1`
  downcases its argument before an exact match, so an account stored with any
  upper-case character was silently unreachable by login. Downcasing repairs
  those accounts; the index in the next migration stops new ones appearing.

  If two rows already differ only by case the migration RAISES rather than
  guessing. Which of two accounts on one address survives — and what happens to
  the shelves hanging off the other — is a decision for a person, not an UPDATE.
  """
  use Ecto.Migration

  def up do
    execute("""
    DO $body$
    DECLARE
      collisions int;
    BEGIN
      SELECT count(*) INTO collisions FROM (
        SELECT lower(email) FROM op.users GROUP BY lower(email) HAVING count(*) > 1
      ) d;

      IF collisions > 0 THEN
        RAISE EXCEPTION
          'op.users holds % email address(es) shared by rows differing only in case. Merge or remove the duplicate accounts before this migration can normalise them.',
          collisions;
      END IF;
    END $body$;
    """)

    execute("UPDATE op.users SET email = lower(email) WHERE email <> lower(email)")
  end

  def down, do: :ok
end
