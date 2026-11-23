defmodule Core.Repo.Migrations.NarrowLookingForHomeToShelvesWithALiveListing do
  @moduledoc """
      The `looking_for_home` read policy on `op.bookshelves` exposed EVERY
      looking_for_home shelf to any reader — including empty ones and ones with
      no live listing. That width was accepted earlier only because the alternative
      ("has an active listing") was a `bookshelf_id IN (SELECT …)` sublink that
      sits under the implicit OR of the permissive policies, stays a SubPlan, and
      can never be an index condition — so narrowing it would have defeated
      indexing of every read of `op.bookshelves` under row-level security, and 20%
      of the table (one of five named shelves per user) is above the threshold an
      index can help.

      This replaces that non-indexable criterion with a maintained, indexed signal:
      a denormalised `active_listing_count` on `op.bookshelves` (added one migration
      back as `NOT NULL DEFAULT 0`), recomputed from truth by a trigger on
      `op.bookshelf_placements`. The policy becomes
      `name = 'looking_for_home' AND active_listing_count > 0` — a same-table,
      indexable predicate served by a partial index — mirroring the `user_id`
      denormalisation that made the owner arm indexable.

      ## Search is preserved exactly, empty shelves stop leaking

      `Shelving.looking_for_home_labels/1` surfaces a shelf only through
      `op.active_listings` (the security_barrier view of `listing_status = 'active'
      AND removed_at IS NULL` placements) and then joins `op.bookshelves` under the
      viewer's own scope to resolve the owner handle. A looking_for_home shelf is
      `visibility: 'owner'`, so that join is served ONLY by this policy arm. Every
      shelf search can surface has at least one active listing, so its
      `active_listing_count > 0` and it stays visible — the search-preserving half.
      A looking_for_home shelf with no live listing now returns to its owner alone.

      ## The count predicate is kept byte-identical to the view

      `listing_status = 'active' AND removed_at IS NULL` is exactly the
      `op.active_listings` predicate. The two must not drift: the policy trusts the
      count to mean "would appear in `op.active_listings`", and the search join
      trusts `op.active_listings` to imply the count is positive.

      ## SECURITY INVOKER — chosen, and why it is sound

      The trigger reads `op.bookshelf_placements` and UPDATEs `op.bookshelves`,
      both FORCE-row-level-security tables scoped on the SAME owner identity
      (`user_id = op.current_scope()`). INVOKER (the default, matching
      `op.set_placement_user_id`) is correct because every context that can mutate
      a placement at all has already satisfied that scoping:

        * Every live writer of a placement's `listing_status`/`removed_at`/
          `bookshelf_id` is the shelf owner acting under their own scope — the
          marketplace activate/deactivate/sold paths `verify_ownership` then scope
          to the seller, the expiry worker scopes to `listing.seller_id`, and the
          shelving place/move/remove/restore paths scope to the acting owner. There
          is NO non-owner write path (no buyer marks a seller's listing); the
          "marketplace purchase marks a seller's listing sold" shape that would
          force DEFINER does not exist — the seller marks their own listing sold.
        * GDPR erasure deletes a user's placements under that same user's scope
          (it leads with `Scope.multi_step/2`), before deleting the shelves, so the
          AFTER-DELETE recount of the still-present owner shelf is permitted.
        * The one cross-user placement mutation in the tree — the catalogue dedup's
          raw DELETE — runs only from a migration, as a role that is either a
          superuser (bypasses RLS on both tables alike) or the FORCE-RLS table
          owner with no scope (which already cannot touch `op.bookshelf_placements`
          at all, since its own owner policy's `op.current_scope()` raises) — so it
          never reaches this trigger in a state where the recount would be blocked.

      In short: because both tables share one owner-scoping model and FORCE status,
      a context permitted to mutate a placement is always permitted the matching
      recount of its shelf. DEFINER (owned by `rls_reader`, the pattern the
      cross-user definer functions use) would make the recount scope-independent,
      but would need a new cross-user `FOR UPDATE` policy and column grant on
      `op.bookshelves` — more standing surface for no reachable gain here.

      The recount is a full recomputation from truth, never a delta, so no ordering
      of inserts/updates/deletes/replays can drift it; the worst a missed fire
      could do is be corrected by the next mutation of the same shelf. The trigger
      fires only on the three columns that can change the count, so a `current_page`
      tick or a `notes` edit does not recount.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    # ── Recount-from-truth, fully-qualified so search_path cannot redirect it ──
    execute("""
    CREATE OR REPLACE FUNCTION op.recompute_bookshelf_active_listing_count()
      RETURNS trigger
      LANGUAGE plpgsql
    AS $$
    DECLARE
      affected uuid[];
      shelf uuid;
    BEGIN
      IF (TG_OP = 'INSERT') THEN
        affected := ARRAY[NEW.bookshelf_id];
      ELSIF (TG_OP = 'DELETE') THEN
        affected := ARRAY[OLD.bookshelf_id];
      ELSIF (NEW.bookshelf_id IS DISTINCT FROM OLD.bookshelf_id) THEN
        -- A move touches both the source and the destination shelf.
        affected := ARRAY[OLD.bookshelf_id, NEW.bookshelf_id];
      ELSE
        affected := ARRAY[NEW.bookshelf_id];
      END IF;

      FOREACH shelf IN ARRAY affected LOOP
        UPDATE op.bookshelves b
           SET active_listing_count = (
             SELECT count(*)
               FROM op.bookshelf_placements p
              WHERE p.bookshelf_id = shelf
                AND p.listing_status = 'active'
                AND p.removed_at IS NULL
           )
         WHERE b.id = shelf;
      END LOOP;

      RETURN NULL;
    END;
    $$
    """)

    # Only INSERT, DELETE, and a change to one of the three columns the count
    # depends on can move it — so the trigger does not fire on a reading-progress
    # or notes update. This is equivalent to "every row change" for the count by
    # construction (nothing else feeds it), and matches the column-targeted shape
    # of the sibling op.set_placement_user_id trigger.
    execute(
      "DROP TRIGGER IF EXISTS recompute_bookshelf_active_listing_count ON op.bookshelf_placements"
    )

    execute("""
    CREATE TRIGGER recompute_bookshelf_active_listing_count
      AFTER INSERT OR DELETE OR UPDATE OF listing_status, removed_at, bookshelf_id
      ON op.bookshelf_placements
      FOR EACH ROW EXECUTE FUNCTION op.recompute_bookshelf_active_listing_count()
    """)

    # ── Backfill from the current active listings ───────────────────────────
    execute("""
    UPDATE op.bookshelves b
       SET active_listing_count = (
         SELECT count(*)
           FROM op.bookshelf_placements p
          WHERE p.bookshelf_id = b.id
            AND p.listing_status = 'active'
            AND p.removed_at IS NULL
       )
    """)

    # ── Narrow the policy to shelves that actually hold a live listing ──────
    execute("DROP POLICY IF EXISTS bookshelves_looking_for_home ON op.bookshelves")

    execute("""
    CREATE POLICY bookshelves_looking_for_home ON op.bookshelves
      FOR SELECT
      USING (name = 'looking_for_home' AND active_listing_count > 0)
    """)

    # The partial index the narrowed arm needs: a handful of shelves ever have a
    # live listing, so `name = 'looking_for_home'` among them is an Index Scan
    # instead of the 20%-selectivity Seq Scan the broad arm forced. Transactional,
    # not CONCURRENTLY: op.bookshelves is small and this runs in the policy
    # transaction so the narrowing and its supporting index land together.
    create index(:bookshelves, [:name],
             prefix: "op",
             name: :bookshelves_looking_for_home_active_idx,
             where: "active_listing_count > 0"
           )

    # ⛔ A policy migration that creates nothing still reports success. Prove the
    # narrowing is actually in place rather than silently left at its old width.
    execute("""
    DO $$ BEGIN
      IF NOT EXISTS (
        SELECT FROM pg_policy p
        JOIN pg_class c ON c.oid = p.polrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'op' AND c.relname = 'bookshelves'
          AND p.polname = 'bookshelves_looking_for_home'
          AND pg_get_expr(p.polqual, p.polrelid) LIKE '%active_listing_count%'
      ) THEN
        RAISE EXCEPTION
          'bookshelves_looking_for_home was not narrowed — every empty looking_for_home shelf would still be world-readable';
      END IF;
    END $$
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    drop_if_exists index(:bookshelves, [:name],
                     prefix: "op",
                     name: :bookshelves_looking_for_home_active_idx
                   )

    execute("DROP POLICY IF EXISTS bookshelves_looking_for_home ON op.bookshelves")

    # Restore the broad arm the previous release expects.
    execute("""
    CREATE POLICY bookshelves_looking_for_home ON op.bookshelves
      FOR SELECT
      USING (name = 'looking_for_home')
    """)

    execute(
      "DROP TRIGGER IF EXISTS recompute_bookshelf_active_listing_count ON op.bookshelf_placements"
    )

    execute("DROP FUNCTION IF EXISTS op.recompute_bookshelf_active_listing_count()")
  end
end
