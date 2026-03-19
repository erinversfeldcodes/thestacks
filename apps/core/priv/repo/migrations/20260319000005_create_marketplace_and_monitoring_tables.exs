defmodule Core.Repo.Migrations.CreateMarketplaceAndMonitoringTables do
  @moduledoc "Creates marketplace tables (offer_threads, offer_messages, listings, transactions) and op.source_health_checks."

  use Ecto.Migration

  def up do
    execute("""
    DO $$ BEGIN
      CREATE TYPE op.offer_thread_status AS ENUM ('open', 'accepted', 'declined', 'expired');
    EXCEPTION WHEN duplicate_object THEN NULL; END $$;
    """)

    execute("""
    DO $$ BEGIN
      CREATE TYPE op.offer_message_type AS ENUM ('message', 'offer', 'counter', 'accept', 'decline');
    EXCEPTION WHEN duplicate_object THEN NULL; END $$;
    """)

    execute("""
    DO $$ BEGIN
      CREATE TYPE op.pricing_mode AS ENUM ('fixed', 'offer');
    EXCEPTION WHEN duplicate_object THEN NULL; END $$;
    """)

    execute("""
    DO $$ BEGIN
      CREATE TYPE op.book_condition AS ENUM ('new', 'like_new', 'good', 'fair', 'poor');
    EXCEPTION WHEN duplicate_object THEN NULL; END $$;
    """)

    execute("""
    DO $$ BEGIN
      CREATE TYPE op.payment_status AS ENUM ('pending', 'paid', 'failed', 'refunded');
    EXCEPTION WHEN duplicate_object THEN NULL; END $$;
    """)

    execute("""
    DO $$ BEGIN
      CREATE TYPE op.shipping_status AS ENUM ('pending', 'shipped', 'delivered', 'returned');
    EXCEPTION WHEN duplicate_object THEN NULL; END $$;
    """)

    # NOTE: op.source_type already exists for op.discovered_sources (bookshop/review_site/...).
    # This enum is distinct — it classifies the source of health check data, not of discovered sources.
    execute("""
    DO $$ BEGIN
      CREATE TYPE op.monitored_source_type AS ENUM ('scraper_config', 'review_source', 'rss_feed', 'event_source', 'llm_output');
    EXCEPTION WHEN duplicate_object THEN NULL; END $$;
    """)

    execute("""
    DO $$ BEGIN
      CREATE TYPE op.health_status AS ENUM ('healthy', 'degraded', 'broken');
    EXCEPTION WHEN duplicate_object THEN NULL; END $$;
    """)

    create table(:offer_threads, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :placement_id,
          references(:bookshelf_placements,
            type: :binary_id,
            prefix: "op",
            on_delete: :delete_all
          ),
          null: false

      add :buyer_id, references(:users, type: :binary_id, prefix: "op", on_delete: :delete_all),
        null: false

      add :status, :text, null: false, default: "open"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:offer_threads, [:placement_id, :buyer_id], prefix: "op")

    create table(:offer_messages, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :thread_id,
          references(:offer_threads, type: :binary_id, prefix: "op", on_delete: :delete_all),
          null: false

      add :sender_id, references(:users, type: :binary_id, prefix: "op", on_delete: :delete_all),
        null: false

      add :type, :text, null: false
      add :body, :text
      add :amount_cents, :integer

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
    end

    create index(:offer_messages, [:thread_id], prefix: "op")

    create table(:listings, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :book_id, references(:books, type: :binary_id, prefix: "op", on_delete: :delete_all),
        null: false

      add :seller_id, references(:users, type: :binary_id, prefix: "op", on_delete: :delete_all),
        null: false

      add :status, :text, null: false, default: "draft"
      add :pricing_mode, :text, null: false
      add :price_cents, :integer, null: false
      add :currency, :text, null: false, default: "ZAR"
      add :condition, :text, null: false
      add :description, :text
      add :photo_urls, {:array, :text}, null: false, default: []
      add :listed_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec
      add :sold_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:listings, [:seller_id], prefix: "op")
    create index(:listings, [:book_id], prefix: "op")

    create table(:transactions, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :listing_id,
          references(:listings, type: :binary_id, prefix: "op", on_delete: :delete_all),
          null: false

      # Soft reference to offer_threads.id — nullable because not all transactions originate
      # from an offer thread (e.g. direct buy). No FK enforced; referential integrity handled
      # at application layer. Revisit in #052 if marketplace context requires hard FK.
      add :offer_id, :binary_id
      # buyer_id and seller_id are nullable with nilify_all for GDPR erasure: when a user
      # account is deleted, transaction records are retained for financial audit but user
      # references are set to NULL. This is intentional.
      add :buyer_id, references(:users, type: :binary_id, prefix: "op", on_delete: :nilify_all)
      add :seller_id, references(:users, type: :binary_id, prefix: "op", on_delete: :nilify_all)
      add :amount_cents, :integer, null: false
      add :currency, :text, null: false, default: "ZAR"
      add :payment_provider_ref, :text
      add :payment_status, :text, null: false, default: "pending"
      add :shipping_provider_ref, :text
      add :shipping_status, :text
      add :shipping_cost_cents, :integer
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
    end

    create index(:transactions, [:listing_id], prefix: "op")

    create table(:source_health_checks, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :source_name, :text, null: false
      add :source_type, :text, null: false
      add :last_success_at, :utc_datetime_usec
      add :last_failure_at, :utc_datetime_usec
      add :last_failure_reason, :text
      add :consecutive_failures, :integer, null: false, default: 0
      add :total_successes, :integer, null: false, default: 0
      add :total_failures, :integer, null: false, default: 0
      add :status, :text, null: false, default: "healthy"

      timestamps(type: :utc_datetime_usec)
    end

    # source_name is the lookup key for health check upserts — must be unique
    create unique_index(:source_health_checks, [:source_name], prefix: "op")

    for table_name <-
          ~w(offer_threads offer_messages listings transactions source_health_checks) do
      execute(
        """
        DO $$ BEGIN
          IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_dbt') THEN
            GRANT SELECT ON op.#{table_name} TO stacks_dbt;
          END IF;
        END $$;
        """,
        """
        DO $$ BEGIN
          IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_dbt') THEN
            REVOKE SELECT ON op.#{table_name} FROM stacks_dbt;
          END IF;
        END $$;
        """
      )
    end
  end

  def down do
    drop table(:source_health_checks, prefix: "op")
    drop table(:transactions, prefix: "op")
    drop table(:listings, prefix: "op")
    drop table(:offer_messages, prefix: "op")
    drop table(:offer_threads, prefix: "op")

    execute("DROP TYPE IF EXISTS op.health_status")
    execute("DROP TYPE IF EXISTS op.monitored_source_type")
    execute("DROP TYPE IF EXISTS op.shipping_status")
    execute("DROP TYPE IF EXISTS op.payment_status")
    execute("DROP TYPE IF EXISTS op.book_condition")
    execute("DROP TYPE IF EXISTS op.pricing_mode")
    execute("DROP TYPE IF EXISTS op.offer_message_type")
    execute("DROP TYPE IF EXISTS op.offer_thread_status")
  end
end
