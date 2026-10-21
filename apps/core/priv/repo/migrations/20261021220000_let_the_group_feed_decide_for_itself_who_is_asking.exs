defmodule Core.Repo.Migrations.LetTheGroupFeedDecideForItselfWhoIsAsking do
  @moduledoc """
      `op.group_feed_placements` takes a GROUP and asks the scope who is
      calling, instead of taking the list of users whose shelves to return.

      ⛔ **The signature was the defect.** Two migrations ago this function was
      created as:

          op.group_feed_placements(member_ids uuid[], before_dt, lim)

      `SECURITY DEFINER`, owned by a role that reads every row, granted to the
      runtime role — and consulting **no scope and no membership**. The caller
      named the users whose shelf activity it wanted and the function returned
      row-level data for them. Every part of the authorisation — is the viewer in
      this group, and are these users actually its members — lived in the
      application code that computed the argument.

      Measured: an **anonymous** session, and a fully unscoped one, could both
      call it with every user id on the platform and it executed without
      raising. It returned zero rows only because this database happens to hold
      no `group`-visibility placements — all 220 are `owner` — so the exposure
      was structural and certain rather than demonstrated. On a stack with real
      group activity, one call would return the N most recent `group`-visibility
      placements platform-wide, ordered and limited.

      ⚠️ Worse than the marketplace equivalent, and the distinction is worth
      keeping: `group` visibility is by definition not public, and **no policy
      arm admits those rows** — which is the entire reason this function exists.
      So it was not "a public arm that is too wide"; it disclosed rows the
      policy set deliberately withholds.

      ## The standing rule this violated, now stated

      ⛔ **A `SECURITY DEFINER` function may take an identifier of the THING
      BEING ASKED ABOUT — a book, an edition, a placement, a group — but never a
      list of the USERS WHOSE ROWS TO RETURN.**

      That is checkable from the signature alone, without reading the body. The
      six sibling functions all satisfy it: `blocked_pair` takes two users but
      is guarded to pairs the scoped user belongs to; `wishlist_user_ids` takes a
      book; `placement_owner` takes an unguessable placement id;
      `platform_row_counts` takes nothing; `unmerge_placement_counts` returns two
      integers. This one took the subject as an argument, and it was the only one
      that did.

      ⚠️ The moduledoc claimed it was "in the same family as the boolean and the
      id-list rather than becoming a general-purpose read". That was a confident
      sentence standing in for a property of the signature — the same shape as a
      revoke justified by a false claim about its callers, and as a gate
      allowlist whose reasons read as verified. The rule above is the version
      that can be checked instead of believed.

      ## Why the member list was passed in, which turns out to be an accident

      Not a design judgement: `op.group_members` and `op.groups` carry no
      row-level security, so the function's owner could always have read them —
      it was simply never granted `SELECT`. Granted here, and the join moves
      inside.

      ## What the viewer guard does and does not permit

      The scope is the only trustworthy statement of who is calling, so the
      function requires `op.scope_user()` to be a member of the group. Unlike
      `op.blocked_pair/2`, an anonymous or unscoped caller is **refused** rather
      than permitted — there is no public path that needs a group feed, and
      `Social.feed_for_group/3` already establishes the viewer before reading.

      ⚠️ `exclude_user_ids` is still an argument and that does not breach the
      rule: it NARROWS the result. It carries the blocked-user filter, which has
      to be applied before the limit or a feed page would silently come back
      short.
  """

  use Ecto.Migration

  def up do
    # The owner role could always have read these — neither carries row-level
    # security — it was only ever missing the grant.
    execute("GRANT SELECT ON op.group_members TO rls_reader")
    execute("GRANT SELECT ON op.groups TO rls_reader")

    execute("DROP FUNCTION IF EXISTS op.group_feed_placements(uuid[], timestamptz, integer)")

    execute("""
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
      -- ⛔ The scope, not an argument. A caller cannot assert who it is; it can
      -- only assert what it is asking about. Refused for an anonymous or
      -- unscoped caller, unlike op.blocked_pair/2, because no public surface
      -- needs a group feed and the context establishes the viewer first.
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
           AND NOT (bs.user_id = ANY(coalesce(exclude_user_ids, ARRAY[]::uuid[])))
           AND (before_dt IS NULL OR p.placed_at < before_dt)
         ORDER BY p.placed_at DESC
         LIMIT lim;
    END
    $$
    """)

    for stmt <- [
          "ALTER FUNCTION op.group_feed_placements(uuid, uuid[], timestamptz, integer) OWNER TO rls_reader",
          "REVOKE ALL ON FUNCTION op.group_feed_placements(uuid, uuid[], timestamptz, integer) FROM PUBLIC",
          "GRANT EXECUTE ON FUNCTION op.group_feed_placements(uuid, uuid[], timestamptz, integer) TO stacks_app"
        ] do
      execute(stmt)
    end
  end

  def down do
    execute(
      "DROP FUNCTION IF EXISTS op.group_feed_placements(uuid, uuid[], timestamptz, integer)"
    )

    # ⚠️ Deliberately NOT restored. The previous signature let any caller name
    # whose shelf activity to return, so recreating it would reopen the
    # disclosure. A rollback past this migration leaves the group feed without
    # its function, which fails loudly, and that is the correct direction.
    execute("REVOKE SELECT ON op.groups FROM rls_reader")
    execute("REVOKE SELECT ON op.group_members FROM rls_reader")
  end
end
