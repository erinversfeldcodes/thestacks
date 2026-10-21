defmodule Core.Repo.Migrations.LetTheUnmergePreviewCountBothSidesOfTheSplit do
  @moduledoc """
      One function, one answer: the two placement counts the unmerge preview
      shows an operator before they approve an irreversible change.

      ⛔ **Why not reuse the per-owner iteration the apply path uses.** That was
      the first attempt and it is wrong for the second count, which is worth
      recording because the error is subtle and the tests caught it immediately.

      The two counts have **different owner sets**:

        * `movers` — placements naming the split edition. Owned by exactly the
          users `op.placement_owners_for_edition/1` returns, so iterating those
          owners inside each one's scope is correct.
        * `retained` — placements on the work that do NOT name the split
          edition. Owned by whoever holds the work's *other* editions, which
          may be a disjoint set of users.

      So looping the edition's owners counted `retained` as 0 for every fixture
      where the two sets differ — a preview reporting "0 placements stay" before
      an operator approves a split that will in fact leave placements behind.
      A wrong number on a confirmation screen is worse than an error on one.

      ⚠️ Returning the two counts rather than the owner set keeps this in the
      same family as the boolean and the id-list: the answer is two integers, so
      nothing about anybody's rows escapes, and there is no second query the
      caller has to get right.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION op.unmerge_placement_counts(edition_id uuid, work_id uuid)
      RETURNS TABLE (movers bigint, retained bigint)
      LANGUAGE sql
      STABLE
      SECURITY DEFINER
      SET search_path = op, pg_temp
    AS $$
      SELECT
        (SELECT count(*) FROM op.bookshelf_placements
          WHERE book_edition_id = edition_id),
        (SELECT count(*) FROM op.bookshelf_placements
          WHERE book_id = work_id
            AND (book_edition_id IS DISTINCT FROM edition_id))
    $$
    """)

    execute("ALTER FUNCTION op.unmerge_placement_counts(uuid, uuid) OWNER TO rls_reader")
    execute("REVOKE ALL ON FUNCTION op.unmerge_placement_counts(uuid, uuid) FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION op.unmerge_placement_counts(uuid, uuid) TO stacks_app")
  end

  def down do
    execute("DROP FUNCTION IF EXISTS op.unmerge_placement_counts(uuid, uuid)")
  end
end
