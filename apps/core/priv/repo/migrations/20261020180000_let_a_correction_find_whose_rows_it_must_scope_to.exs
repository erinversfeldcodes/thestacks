defmodule Core.Repo.Migrations.LetACorrectionFindWhoseRowsItMustScopeTo do
  @moduledoc """
      The one cross-user WRITE in this codebase, made scoped rather than
      exempted.

      ⛔ `DataCorrection.UnmergeEdition.apply_change/1` re-points every placement
      naming a split edition, and those placements belong to whichever users
      hold that edition. Under the row-level policies a single `update_all`
      cannot do that: whichever user the scope names, every other user's rows
      are invisible to it. And unlike the three read cases, a `SECURITY DEFINER`
      *read* does not solve a write.

      ## Why this is a read function and not a write exemption

      ⚠️ The obvious fixes were both worse. A `SECURITY DEFINER` function that
      performed the UPDATE would be a standing ability to rewrite any user's
      placements, reachable by anything that can execute it. An exemption for
      the deploy-time owner identity would be a standing full-table write
      identity — defensible, since `FORCE ROW LEVEL SECURITY` was enabled to stop
      the application bypassing policies back when the application connected as
      the owner, but it buys a broad grant for a narrow problem.

      ✅ What the correction actually lacks is one fact: **whose** rows are
      affected. So that is all this function returns. The correction then groups
      by owner and runs its update once inside each owner's scope, and the
      policy — not the query — is what confines each update to that owner's
      placements. Every write in the system stays scoped to exactly one user,
      which keeps the invariant total.

      ⚠️ Granted to `PUBLIC` deliberately, and it is not a widening. The
      correction runs on the OWNER connection (`Stacks.Release.correct_data/1`
      goes through the owner repo) while the application runs as `stacks_app`,
      and the owner role is named differently in every environment — so naming
      roles here would be a list that rots. The function discloses only which
      users hold a placement for a given edition, and the two roles that could
      learn more from it, `stacks_dbt` and `stacks_readonly`, already hold
      `USING (true)` read policies on these tables.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    execute("""
    CREATE OR REPLACE FUNCTION op.placement_owners_for_edition(edition_id uuid)
      RETURNS TABLE (user_id uuid)
      LANGUAGE sql
      STABLE
      SECURITY DEFINER
      SET search_path = op, pg_temp
    AS $$
      SELECT DISTINCT bs.user_id
        FROM op.bookshelves bs
        JOIN op.bookshelf_placements p ON p.bookshelf_id = bs.id
       WHERE p.book_edition_id = edition_id
    $$
    """)

    execute("ALTER FUNCTION op.placement_owners_for_edition(uuid) OWNER TO rls_reader")
    execute("GRANT EXECUTE ON FUNCTION op.placement_owners_for_edition(uuid) TO PUBLIC")
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    execute("DROP FUNCTION IF EXISTS op.placement_owners_for_edition(uuid)")
  end
end
