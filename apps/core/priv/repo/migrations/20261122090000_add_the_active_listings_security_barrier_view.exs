defmodule Core.Repo.Migrations.AddTheActiveListingsSecurityBarrierView do
  use Ecto.Migration

  # Moves the active-listing read off a row-level policy arm and onto a narrow
  # security_barrier view. A policy has no column list, so the active_listing arm
  # handed any scoped reader EVERY column of another user's active placement —
  # including listing_min_price_cents (the seller's reserve) and notes. The view's
  # select-list IS the column allowlist: book_id and bookshelf_id (the discovery
  # label resolves the owner's handle through the bookshelf) and placed_at (the
  # label shows the most recently offered owner first). Nothing sensitive.
  #
  # Owned by rls_reader, which holds a `FOR SELECT TO rls_reader USING (true)`
  # read policy on the base table, so the view sees every active row regardless of
  # the caller's scope. The view's WHERE and select-list are therefore the whole
  # boundary — which is why `security_barrier` is load-bearing and not decoration:
  # without it a caller's WHERE can be pushed below the view's qual through a leaky
  # operator and used to probe filtered-out rows.
  #
  # Inert at creation. The search read-switch that consumes it, and the drop of
  # the active_listing policy arm, land in the same change but ordered after this.
  def up do
    execute("""
    CREATE VIEW op.active_listings WITH (security_barrier) AS
      SELECT p.id, p.book_id, p.bookshelf_id, p.placed_at
        FROM op.bookshelf_placements p
       WHERE p.listing_status = 'active' AND p.removed_at IS NULL
    """)

    execute("ALTER VIEW op.active_listings OWNER TO rls_reader")
    execute("GRANT SELECT ON op.active_listings TO stacks_app")
  end

  def down do
    execute("DROP VIEW IF EXISTS op.active_listings")
  end
end
