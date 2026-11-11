defmodule Core.Repo.Migrations.LetThePublicTierActuallyBePublicAndTheMembersTierRequireAMember do
  @moduledoc """
      Replaces the two `platform_select` read policies with tier-aware ones, so
      `public` is visible to everyone and `platform` requires a signed-in reader.

      ## The defect: the ladder was inverted at its top rung

      The visibility tiers are `owner` ("Only me"), `platform`
      ("Members (signed-in users)") and `public` ("Anyone with the link"). The
      read policies had an arm for `platform` and **no arm for `public` at all**:

          bookshelves_platform_select        USING (visibility = 'platform')
          bookshelf_placements_platform_select
              USING (visibility = 'platform' AND bookshelf_id IN (
                       SELECT id FROM op.bookshelves WHERE visibility = 'platform'))

      A row's `visibility` holds exactly one value, so a `public` row does not
      satisfy `visibility = 'platform'`. The consequence is that the **more
      open** tier was **less** readable than the members-only tier: choosing
      "Anyone with the link" made a bookshelf disappear instead of publishing it.

      Measured as the runtime role with a signed-in non-owner's scope set:

          the public bookshelf, by id                      → 0 rows
          rows a non-owner could see, grouped by tier:
            owner      19     (the looking_for_home arm, a separately accepted width)
            platform    6
            public      — absent entirely —

      ⚠️ **And it failed open as an empty list, not as an error**, because a
      non-matching policy filters rows rather than raising. So an anonymous read
      of a public profile answered `200` with `"bookshelves": []` — a reader with
      a published shelf was indistinguishable from a reader with no shelves.

      ## The second half: `platform` did not require a member

      The predecessor that taught `op.current_scope()` to return NULL for a
      deliberately anonymous reader describes the remaining arms as "the ones
      that say a row is public", and lists `op.bookshelves — visibility =
      'platform'` among them. That is the inversion stated out loud: the arm it
      calls public is the **members-only** tier, so an anonymous reader reached
      `platform` rows at the database layer.

      Nothing leaked, because the application layer enforces the members
      boundary — `Stacks.Feeds` checks `feed_requires_auth?/1` before it touches
      the cache, which was verified directly against all three tiers. ⛔ But
      that made the guarantee depend on every present and future caller
      remembering an application-level check, with the policy layer *more*
      permissive than the label it implements. Defence in depth was inverted:
      the outer layer was the only layer.

      So these policies now answer the tier question themselves:

          anonymous  (op.current_scope() IS NULL)      → public only
          signed in  (op.current_scope() IS NOT NULL)  → public + platform

      ⚠️ **This is a tightening as well as a widening**, and the tightening is
      the part to watch in review: an anonymous reader that previously reached a
      `platform` row at the database layer no longer does. Any surface that was
      *relying* on that — rather than gating in application code as the feed
      path does — will go from returning rows to returning none. The feed,
      search, catalogue, marketplace and public-profile paths were the ones
      enumerated when the anonymous sentinel was introduced; those are the
      surfaces to re-drive.

      ## Why the conjunction on placements is preserved

      A placement is only as visible as the shelf it sits on, so both halves are
      asked for the same viewer. A `public` placement on a `platform` bookshelf
      stays invisible to an anonymous reader, because the *shelf* is
      members-only; a `platform` placement on a `public` bookshelf likewise.
      Collapsing that to a single check on the placement would publish rows
      whose container is private.

      ## Why renamed rather than redefined under the old name

      `*_platform_select` would be a lie about a policy that also selects
      `public`, and a misleading policy name is exactly the sort of thing the
      next reader trusts. `audience` is the word the unified-visibility decision
      already uses for this ladder. `docs/rls-design.md` is updated in the same
      change; the older migrations keep their text because they are a record of
      what was true when they ran.

      ⛔ **The refusal on an unscoped query is deliberately unchanged.** Both new
      arms call `op.current_scope()`, which still raises when no scope was ever
      set, so "somebody forgot to scope" remains distinguishable from "there is
      genuinely nobody here" — the property the sentinel exists to provide.
      Permissive policies are combined with `OR` and Postgres gives no
      short-circuit guarantee, so a row satisfying the public arm still
      evaluates the owner arm and still raises on an unscoped read.
  """
  use Ecto.Migration

  # ⚠️ One statement per `execute/1`. Postgrex sends these as prepared
  # statements, which reject multiple commands in one string — a semicolon-joined
  # DDL block fails with `42601 cannot insert multiple commands into a prepared
  # statement`, and because Ecto wraps a migration in a transaction the failure
  # rolls the whole thing back rather than leaving it half-applied.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    execute("DROP POLICY IF EXISTS bookshelves_platform_select ON op.bookshelves")
    execute("DROP POLICY IF EXISTS bookshelves_audience_select ON op.bookshelves")
    execute(bookshelves_audience_policy())

    execute(
      "DROP POLICY IF EXISTS bookshelf_placements_platform_select ON op.bookshelf_placements"
    )

    execute(
      "DROP POLICY IF EXISTS bookshelf_placements_audience_select ON op.bookshelf_placements"
    )

    execute(placements_audience_policy())

    execute(assert_tiers())
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    execute(
      "DROP POLICY IF EXISTS bookshelf_placements_audience_select ON op.bookshelf_placements"
    )

    execute(placements_platform_policy())

    execute("DROP POLICY IF EXISTS bookshelves_audience_select ON op.bookshelves")
    execute(bookshelves_platform_policy())
  end

  defp bookshelves_audience_policy do
    """
    CREATE POLICY bookshelves_audience_select ON op.bookshelves
      FOR SELECT
      USING (
        visibility = 'public'
        OR (visibility = 'platform' AND op.current_scope() IS NOT NULL)
      )
    """
  end

  defp bookshelves_platform_policy do
    """
    CREATE POLICY bookshelves_platform_select ON op.bookshelves
      FOR SELECT
      USING (visibility = 'platform')
    """
  end

  defp placements_audience_policy do
    """
    CREATE POLICY bookshelf_placements_audience_select ON op.bookshelf_placements
      FOR SELECT
      USING (
        (
          visibility = 'public'
          OR (visibility = 'platform' AND op.current_scope() IS NOT NULL)
        )
        AND bookshelf_id IN (
          SELECT b.id
          FROM op.bookshelves b
          WHERE b.visibility = 'public'
             OR (b.visibility = 'platform' AND op.current_scope() IS NOT NULL)
        )
      )
    """
  end

  defp placements_platform_policy do
    """
    CREATE POLICY bookshelf_placements_platform_select ON op.bookshelf_placements
      FOR SELECT
      USING (
        visibility = 'platform'
        AND bookshelf_id IN (
          SELECT id FROM op.bookshelves WHERE visibility = 'platform'
        )
      )
    """
  end

  # ⛔ The far end. A policy migration that creates nothing still reports
  # success, and the symptom this fixes was a silent empty list — so the one
  # thing this must not do is leave the system quietly in its old shape.
  defp assert_tiers do
    """
    DO $$ BEGIN
      IF NOT EXISTS (
        SELECT FROM pg_policy p
        JOIN pg_class c ON c.oid = p.polrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'op' AND c.relname = 'bookshelves'
          AND p.polname = 'bookshelves_audience_select'
      ) THEN
        RAISE EXCEPTION
          'bookshelves_audience_select was not created — a public bookshelf would still be readable by nobody';
      END IF;

      IF NOT EXISTS (
        SELECT FROM pg_policy p
        JOIN pg_class c ON c.oid = p.polrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'op' AND c.relname = 'bookshelf_placements'
          AND p.polname = 'bookshelf_placements_audience_select'
      ) THEN
        RAISE EXCEPTION
          'bookshelf_placements_audience_select was not created — a public placement would still be readable by nobody';
      END IF;

      IF EXISTS (
        SELECT FROM pg_policy p
        JOIN pg_class c ON c.oid = p.polrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'op'
          AND c.relname IN ('bookshelves', 'bookshelf_placements')
          AND p.polname LIKE '%_platform_select'
      ) THEN
        RAISE EXCEPTION
          'a platform_select policy survives alongside its replacement — permissive policies OR together, so the old arm would keep granting anonymous access to the members tier';
      END IF;
    END $$;
    """
  end
end
