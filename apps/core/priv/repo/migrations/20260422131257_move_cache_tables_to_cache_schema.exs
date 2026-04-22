defmodule Core.Repo.Migrations.MoveCacheTablesToCacheSchema do
  use Ecto.Migration

  # Schema DDL (CREATE/ALTER/DROP SCHEMA and ALTER TABLE ... SET SCHEMA) is
  # implicit-transaction safe in Postgres — no CONCURRENTLY required. The
  # tables are small (~1h of cached data, plus most rows TTL within 24h),
  # and `ALTER TABLE ... SET SCHEMA` is a metadata-only rename that holds
  # an ACCESS EXCLUSIVE lock for microseconds. Keeping the default DDL
  # transaction means the whole move (two tables + grant shuffle) is atomic.

  def up do
    execute("CREATE SCHEMA IF NOT EXISTS cache")

    execute("ALTER TABLE op.isbn_resolver_cache SET SCHEMA cache")
    execute("ALTER TABLE op.title_search_cache SET SCHEMA cache")

    # stacks_dbt lost SELECT implicitly when the tables moved — the op-level
    # GRANT SELECT from migration 20260305000020 was table-bound, not
    # schema-bound, but make the revocation explicit for the down/0 path
    # to have a mirror. Cache tables have no analytical value and dbt
    # staging models for them are removed in this same change.
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_dbt') THEN
        REVOKE SELECT ON cache.isbn_resolver_cache FROM stacks_dbt;
        REVOKE SELECT ON cache.title_search_cache FROM stacks_dbt;
      END IF;
    END $$;
    """)

    # stacks_app needs full CRUD on the new schema — the cache modules
    # insert, update (upsert), and delete rows from the Elixir app's
    # pool. The GRANTs on SCHEMA op from 20260305000020 do not cascade
    # to cache because that's a separate namespace.
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_app') THEN
        GRANT USAGE ON SCHEMA cache TO stacks_app;
        GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA cache TO stacks_app;
        ALTER DEFAULT PRIVILEGES IN SCHEMA cache
          GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO stacks_app;
      END IF;
    END $$;
    """)
  end

  def down do
    # Reverse order: drop stacks_app privileges, re-grant dbt SELECT on op,
    # move tables back, drop the (now-empty) cache schema.
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_app') THEN
        ALTER DEFAULT PRIVILEGES IN SCHEMA cache
          REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM stacks_app;
        REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA cache FROM stacks_app;
        REVOKE USAGE ON SCHEMA cache FROM stacks_app;
      END IF;
    END $$;
    """)

    execute("ALTER TABLE cache.title_search_cache SET SCHEMA op")
    execute("ALTER TABLE cache.isbn_resolver_cache SET SCHEMA op")

    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_dbt') THEN
        GRANT SELECT ON op.isbn_resolver_cache TO stacks_dbt;
        GRANT SELECT ON op.title_search_cache TO stacks_dbt;
      END IF;
    END $$;
    """)

    execute("DROP SCHEMA IF EXISTS cache")
  end
end
