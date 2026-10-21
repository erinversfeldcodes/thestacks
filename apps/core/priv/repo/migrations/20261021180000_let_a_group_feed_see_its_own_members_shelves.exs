defmodule Core.Repo.Migrations.LetAGroupFeedSeeItsOwnMembersShelves do
  @moduledoc """
      The group feed asks a question no per-user scope can answer: which
      `group`-visibility placements do the members of this group have.

      ⛔ **Found by a stacked defect, which is why it is worth recording how.**
      The group feed had two unscoped reads in sequence. The first —
      `Social.blocked_user_ids/1` — raised, so `GET /api/groups/:id/feed`
      returned `42501` from there and the second was never reached. Fixing the
      first moved the failure to the second rather than fixing the endpoint. The
      review predicted this exactly ("#3 stays invisible until #2 is fixed")
      and this project already has the lesson on record from four `/admin/*`
      bugs in sequence, each invisible until the one in front of it was fixed.
      **Re-drive after every fix.**

      ## Why a definer and not a policy arm

      A policy admitting `visibility = 'group'` rows to a reader who shares a
      group with the owner needs a group-membership join **in the policy body**,
      which the planner then carries on every read of
      `op.bookshelf_placements` — including the ones that have nothing to do
      with groups. That is the sequential-scan shape already measured and
      rejected for a sentinel term, and a third permissive policy would also
      keep the owner arm's disjunction unindexable.

      So the group feed gets one function answering one question, and the base
      table's policy set stays as narrow as it is.

      ## Why it returns ids and a timestamp, not the feed rows

      `op.bookshelf_placements` and `op.bookshelves` are the secured tables;
      `op.books` and `op.users` are not. So this function returns only what it
      must — which placement, whose, for which book, and when — and the caller
      joins the book title and the display name itself through tables that need
      no privilege. Nothing about anybody's shelf escapes beyond the four values
      the feed already displays, which keeps it in the same family as the
      boolean and the id-list rather than becoming a general-purpose read.

      ⚠️ The ordering and the limit are INSIDE the function, because "the most
      recent N" cannot be computed correctly by a caller that was handed an
      unordered subset.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION op.group_feed_placements(
      member_ids uuid[],
      before_dt timestamptz,
      lim integer
    )
      RETURNS TABLE (placement_id uuid, book_id uuid, owner_id uuid, placed_at timestamptz)
      LANGUAGE sql
      STABLE
      SECURITY DEFINER
      SET search_path = op, pg_temp
    AS $$
      SELECT p.id, p.book_id, bs.user_id, p.placed_at
        FROM op.bookshelf_placements p
        JOIN op.bookshelves bs ON bs.id = p.bookshelf_id
       WHERE bs.user_id = ANY(member_ids)
         AND p.visibility IN ('group', 'platform')
         AND p.removed_at IS NULL
         AND (before_dt IS NULL OR p.placed_at < before_dt)
       ORDER BY p.placed_at DESC
       LIMIT lim
    $$
    """)

    execute(
      "ALTER FUNCTION op.group_feed_placements(uuid[], timestamptz, integer) OWNER TO rls_reader"
    )

    execute(
      "REVOKE ALL ON FUNCTION op.group_feed_placements(uuid[], timestamptz, integer) FROM PUBLIC"
    )

    execute(
      "GRANT EXECUTE ON FUNCTION op.group_feed_placements(uuid[], timestamptz, integer) TO stacks_app"
    )
  end

  def down do
    execute("DROP FUNCTION IF EXISTS op.group_feed_placements(uuid[], timestamptz, integer)")
  end
end
