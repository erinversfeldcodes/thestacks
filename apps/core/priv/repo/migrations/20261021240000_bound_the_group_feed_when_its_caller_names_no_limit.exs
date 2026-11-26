defmodule Core.Repo.Migrations.BoundTheGroupFeedWhenItsCallerNamesNoLimit do
  @moduledoc """
      `LIMIT lim` with a NULL `lim` is `LIMIT ALL`, so a caller passing no limit
      got every `group`- and `platform`-visibility placement for the group with
      no cap.

      ⚠️ **Not a disclosure.** It stays entirely inside what `group_id` plus the
      membership guard already admit, so the monotonicity property holds: the
      limit is a narrowing parameter and removing it widens the result only to
      the ceiling the subject identifier already sets. What it is instead is an
      **unbounded read reachable from a request parameter** — the Elixir caller
      clamps to 50, but the function is the thing with the grant and it should
      not depend on its caller's arithmetic for a bound.

      ⛔ A negative `lim` already errors, so only the NULL direction was open.
  """

  use Ecto.Migration

  def up, do: execute(fn_sql("coalesce(lim, 100)"))

  def down, do: execute(fn_sql("lim"))

  # One body, two limit expressions — so the rollback cannot drift from the
  # forward version in any other respect.
  defp fn_sql(limit_expr) do
    """
    CREATE OR REPLACE FUNCTION op.group_feed_placements(
      group_id uuid,
      exclude_user_ids uuid[],
      before_dt timestamptz,
      lim integer
    )
      RETURNS TABLE (placement_id uuid, book_id uuid, owner_id uuid, placed_at timestamptz)
      LANGUAGE plpgsql
      STABLE
      SECURITY DEFINER
      SET search_path = op, pg_temp
    AS $$
    DECLARE
      asker uuid := op.scope_user();
    BEGIN
      IF asker IS NULL THEN
        RAISE EXCEPTION 'a group feed requires a scoped viewer'
          USING ERRCODE = '42501',
                HINT = 'wrap the read in Stacks.Scope.with_user/2 with the viewer';
      END IF;

      IF NOT EXISTS (
        SELECT 1 FROM op.group_members gm
         WHERE gm.group_id = group_feed_placements.group_id
           AND gm.user_id = asker
      ) THEN
        RAISE EXCEPTION 'the scoped viewer is not a member of this group'
          USING ERRCODE = '42501';
      END IF;

      RETURN QUERY
        SELECT p.id, p.book_id, bs.user_id, p.placed_at
          FROM op.bookshelf_placements p
          JOIN op.bookshelves bs ON bs.id = p.bookshelf_id
          JOIN op.group_members m ON m.user_id = bs.user_id
         WHERE m.group_id = group_feed_placements.group_id
           AND p.visibility IN ('group', 'platform')
           AND p.removed_at IS NULL
           -- The `coalesce` is load-bearing: without it a NULL exclude list
           -- makes `NOT (x = ANY(NULL))` evaluate to NULL and filters out
           -- EVERY row, returning an empty feed rather than an unfiltered one.
           AND NOT (bs.user_id = ANY(coalesce(exclude_user_ids, ARRAY[]::uuid[])))
           AND (before_dt IS NULL OR p.placed_at < before_dt)
         ORDER BY p.placed_at DESC
         LIMIT #{limit_expr};
    END
    $$
    """
  end
end
