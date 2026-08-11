defmodule Core.Repo.Migrations.DowncaseUserEmails do
  @moduledoc """
    Downcases every stored email so the case-insensitive unique index in
    `20260730200500` has nothing to trip over. The old exact-match
    index allowed two accounts on one address — and since
    `get_user_by_email/1` downcases before matching, an account stored with
    any upper-case character was unreachable by login. This repairs those;
    the index stops new ones.
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
