defmodule Core.Repo.Migrations.MoveCacheTablesToCacheSchema do
  use Ecto.Migration

  def up do
    execute("CREATE SCHEMA IF NOT EXISTS cache")

    execute("ALTER TABLE op.isbn_resolver_cache SET SCHEMA cache")
    execute("ALTER TABLE op.title_search_cache SET SCHEMA cache")

    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_dbt') THEN
        REVOKE SELECT ON cache.isbn_resolver_cache FROM stacks_dbt;
        REVOKE SELECT ON cache.title_search_cache FROM stacks_dbt;
      END IF;
    END $$;
    """)

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
