defmodule Core.Repo.Migrations.DropThePlacementWideningArmsAndMakeTheOwnerArmIndexable do
  use Ecto.Migration

  # Release C of the exposure-closing. Safe only because the one application read
  # that depended on a widening arm — the search discovery label — now reads the
  # op.active_listings security_barrier view (the previous migration + the
  # looking_for_home_labels switch), and the public shelf-browse never used a
  # widening arm at all: it scopes every placement read to the shelf OWNER and
  # narrows in the application, so it reads through the owner arm.
  #
  # ⚠️ DEPLOY-WINDOW TRADE-OFF, accepted deliberately. This drop (Release C) and the
  # view + read-switch (Release B) ship in ONE deploy, and migrations run before the
  # new machines serve — so during a rolling deploy an old machine still reads the
  # base table via the active_listing arm, and once this migration drops it that
  # machine's looking-for-home search labels go empty until the rollout finishes.
  # The original design called the B/C split uncollapsible because it feared the
  # signed-out /api/listings read would break — but a wiring trace established that
  # read goes to op.listings (no RLS), not to a placement arm, so that failure
  # cannot occur. The only exposed path is the looking-for-home SEARCH label: it
  # fails SAFE (an empty label, never over-exposure), self-heals when the rollout
  # completes, and is currently immaterial (zero active looking_for_home listings).
  # The window is accepted rather than split into two deploys because it cannot harm
  # the current state and tightens, never widens, access.
  #
  # With both widening arms gone, the owner arm is the only permissive policy
  # stacks_app meets, and rewriting its USING as a same-table equality on the
  # denormalised user_id makes it an indexable Bitmap Index Scan instead of a
  # SubPlan no index can serve (a sublink under OR can never be pulled into a
  # semi-join).
  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    execute(
      "DROP POLICY IF EXISTS bookshelf_placements_active_listing ON op.bookshelf_placements"
    )

    execute(
      "DROP POLICY IF EXISTS bookshelf_placements_audience_select ON op.bookshelf_placements"
    )

    execute("DROP POLICY IF EXISTS bookshelf_placements_owner ON op.bookshelf_placements")

    # WITH CHECK stays bookshelf-based on purpose. It validates an INSERT/UPDATE's
    # bookshelf_id — which the application always supplies — so it does not depend
    # on the set_placement_user_id trigger having already run (BEFORE-trigger vs
    # WITH-CHECK ordering), and it is a per-row point check, not a scan, so it
    # carries no indexability cost. It stays consistent with the USING: a row whose
    # bookshelf the caller owns gets user_id = caller via the trigger.
    execute("""
    CREATE POLICY bookshelf_placements_owner ON op.bookshelf_placements
      USING (user_id = op.current_scope())
      WITH CHECK (
        bookshelf_id IN (
          SELECT id FROM op.bookshelves WHERE user_id = op.current_scope()
        )
      )
    """)
  end

  def down do
    execute("DROP POLICY IF EXISTS bookshelf_placements_owner ON op.bookshelf_placements")

    execute("""
    CREATE POLICY bookshelf_placements_owner ON op.bookshelf_placements
      USING (
        bookshelf_id IN (
          SELECT id FROM op.bookshelves WHERE user_id = op.current_scope()
        )
      )
      WITH CHECK (
        bookshelf_id IN (
          SELECT id FROM op.bookshelves WHERE user_id = op.current_scope()
        )
      )
    """)

    execute("""
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
    """)

    execute("""
    CREATE POLICY bookshelf_placements_active_listing ON op.bookshelf_placements
      FOR SELECT
      USING (listing_status = 'active' AND removed_at IS NULL)
    """)
  end
end
