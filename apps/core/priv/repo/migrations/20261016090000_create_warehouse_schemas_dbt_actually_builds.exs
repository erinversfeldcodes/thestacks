defmodule Core.Repo.Migrations.CreateWarehouseSchemasDbtActuallyBuilds do
  @moduledoc """
      dbt has never successfully run against a deployed database, and the
      schemas were one of four independent reasons why.

      `dbt/dbt_project.yml` materialises each layer into its own schema —
      `staging`, `intermediate`, `marts` — but only `op`, `wh` and `audit` were
      ever created. Meanwhile every warehouse GRANT was aimed at `wh`, the one
      schema dbt does not write to, and `stacks_dbt` was never granted CREATE
      on anything at all, so it could not have materialised a view even in the
      right place.

      ⚠️ `wh` is deliberately LEFT IN PLACE and left empty. It is the fallback
      `dbt/profiles.yml` names as the target schema, so a model filed outside
      the three layer directories lands there. Keeping it means that mistake is
      visible as rows in a schema nothing reads, rather than a dbt error about
      a missing schema that someone fixes by creating it. The companion
      assertion lives in the dbt-model-drift gate.
  """

  use Ecto.Migration

  @schemas ~w(staging intermediate marts)

  def up do
    for schema <- @schemas do
      execute("CREATE SCHEMA IF NOT EXISTS #{schema}")
    end

    execute(grants_up(), grants_down())
  end

  def down do
    execute(grants_down(), grants_up())

    for schema <- @schemas do
      execute("DROP SCHEMA IF EXISTS #{schema} CASCADE")
    end
  end

  defp grants_up do
    """
    DO $$ BEGIN
      -- stacks_dbt BUILDS here, so it needs CREATE on the schema — not just
      -- CRUD on the tables. The original role migration granted CRUD on `wh`
      -- and CREATE on nothing, which is why dbt could not materialise a view
      -- anywhere regardless of which schema it aimed at.
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_dbt') THEN
        GRANT USAGE, CREATE ON SCHEMA staging TO stacks_dbt;
        GRANT USAGE, CREATE ON SCHEMA intermediate TO stacks_dbt;
        GRANT USAGE, CREATE ON SCHEMA marts TO stacks_dbt;
      END IF;

      -- stacks_app READS marts and nothing else. Staging and intermediate are
      -- dbt's working surfaces; the app has no business in them, and several
      -- staging models carry columns the warehouse rules keep out of reader
      -- reach.
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_app') THEN
        GRANT USAGE ON SCHEMA marts TO stacks_app;
        GRANT SELECT ON ALL TABLES IN SCHEMA marts TO stacks_app;
      END IF;

      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_readonly') THEN
        GRANT USAGE ON SCHEMA marts TO stacks_readonly;
        GRANT SELECT ON ALL TABLES IN SCHEMA marts TO stacks_readonly;
      END IF;
    END $$;
    """
  end

  # ⚠️ The grants above cover relations that exist RIGHT NOW — of which there
  # are none, because dbt has never run. Every view dbt creates AFTER this
  # migration would be unreadable by the app, so something has to grant on the
  # new relations.
  #
  # `ALTER DEFAULT PRIVILEGES FOR ROLE stacks_dbt` is the obvious answer and it
  # DOES NOT BELONG HERE. Postgres requires the caller to own or be a member of
  # the role whose defaults it alters, and the migration role is neither.
  # Verified against a fresh database with a non-superuser migrator:
  #
  #     ERROR:  permission denied to change default privileges
  #
  # In an Ecto migration that aborts the migration and therefore the deploy.
  # It passes locally only because the dev migrator is a superuser — exactly
  # the shape of difference that turns into a production-only failure.
  #
  # The grant lives in dbt's `on-run-end` hook instead (`dbt/dbt_project.yml`),
  # which runs as `stacks_dbt` — the role that owns the relations and can
  # therefore grant on them without any membership question. It also re-grants
  # on every build, which matters because a view that is dropped and recreated
  # loses its ACL.

  defp grants_down do
    """
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_readonly') THEN
        REVOKE ALL ON SCHEMA marts FROM stacks_readonly;
      END IF;

      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_app') THEN
        REVOKE ALL ON SCHEMA marts FROM stacks_app;
      END IF;

      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_dbt') THEN
        REVOKE ALL ON SCHEMA staging FROM stacks_dbt;
        REVOKE ALL ON SCHEMA intermediate FROM stacks_dbt;
        REVOKE ALL ON SCHEMA marts FROM stacks_dbt;
      END IF;
    END $$;
    """
  end
end
