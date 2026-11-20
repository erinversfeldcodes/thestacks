defmodule Core.Repo.Migrations.GiveTheMovedCacheTablesTheirRuntimeGrants do
  @moduledoc """
      Re-asserts, now that the runtime role exists everywhere, the grants the
      cache-schema move intended: the move migration DID write them, inside a
      role-guard — and on the staging lineage it ran before `stacks_app`
      existed, so the guard silently skipped and every deployed environment
      has refused every L2 cache write since (`:insufficient_privilege`;
      verified live against the preview branch: no USAGE on schema cache, no
      INSERT on either table). Local tests connect as a superuser and
      structurally cannot see it.

      ⚠️ THE CLASS, not just the instance: a role-guarded grant is
      ORDER-DEPENDENT — it evaporates on any lineage where the role arrives
      after the migration, and nothing ever re-checks. A live-DB sweep
      (2026-11-20, preview branch) found exactly these two tables missing
      `stacks_app` INSERT across op/cache/audit, so this re-assert closes
      every known instance. Guarded the same way on purpose: a fresh dev DB
      without roles must still migrate, and every DEPLOYED lineage now has
      the role, which is the fact that makes the re-assert effective where
      the original was vacuous.
  """
  use Ecto.Migration

  def up do
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
        REVOKE SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA cache FROM stacks_app;
        REVOKE USAGE ON SCHEMA cache FROM stacks_app;
      END IF;
    END $$;
    """)
  end
end
