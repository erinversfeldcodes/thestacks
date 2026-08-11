defmodule Core.Repo.Migrations.FixMarketplaceMonitoringConstraints do
  @moduledoc """
      Applies three corrections to migrations 000005:

      1. Creates op.monitored_source_type enum (renamed from the incorrect op.source_type
         which was silently a no-op due to name collision with op.discovered_sources source_type).
      2. Alters transactions.buyer_id and transactions.seller_id FK constraints from
         ON DELETE RESTRICT to ON DELETE SET NULL (GDPR erasure pattern — retain financial
         records but null out user references on account deletion).
      3. Adds unique index on source_health_checks.source_name (required for upsert pattern).
  """

  use Ecto.Migration

  def up do
    execute("""
    DO $$ BEGIN
      CREATE TYPE op.monitored_source_type AS ENUM ('scraper_config', 'review_source', 'rss_feed', 'event_source', 'llm_output');
    EXCEPTION WHEN duplicate_object THEN NULL; END $$;
    """)

    execute("ALTER TABLE op.transactions DROP CONSTRAINT IF EXISTS transactions_buyer_id_fkey")
    execute("ALTER TABLE op.transactions DROP CONSTRAINT IF EXISTS transactions_seller_id_fkey")

    execute("""
    ALTER TABLE op.transactions
      ADD CONSTRAINT transactions_buyer_id_fkey
        FOREIGN KEY (buyer_id) REFERENCES op.users(id) ON DELETE SET NULL
    """)

    execute("""
    ALTER TABLE op.transactions
      ADD CONSTRAINT transactions_seller_id_fkey
        FOREIGN KEY (seller_id) REFERENCES op.users(id) ON DELETE SET NULL
    """)

    create_if_not_exists unique_index(:source_health_checks, [:source_name], prefix: "op")
  end

  def down do
    drop_if_exists unique_index(:source_health_checks, [:source_name], prefix: "op")

    execute("ALTER TABLE op.transactions DROP CONSTRAINT IF EXISTS transactions_buyer_id_fkey")
    execute("ALTER TABLE op.transactions DROP CONSTRAINT IF EXISTS transactions_seller_id_fkey")

    execute("""
    ALTER TABLE op.transactions
      ADD CONSTRAINT transactions_buyer_id_fkey
        FOREIGN KEY (buyer_id) REFERENCES op.users(id) ON DELETE NO ACTION
    """)

    execute("""
    ALTER TABLE op.transactions
      ADD CONSTRAINT transactions_seller_id_fkey
        FOREIGN KEY (seller_id) REFERENCES op.users(id) ON DELETE NO ACTION
    """)

    execute("DROP TYPE IF EXISTS op.monitored_source_type")
  end
end
