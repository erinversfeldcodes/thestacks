defmodule Core.Repo.Migrations.CreateTheRolesTheWarehouseGrantsAssume do
  @moduledoc """
      Creates `stacks_app`, `stacks_dbt` and `stacks_readonly` where they are
      missing, and grants them on the schemas that actually exist.

      ## Why a second role migration

      `20260305000020_create_db_roles.exs` already does this, and it has run
      everywhere — which is the problem. It creates a role only when
      `STACKS_APP_DB_PASSWORD` / `STACKS_DBT_DB_PASSWORD` is present in the
      environment, the deploy set neither, and every grant in it is wrapped in
      `IF EXISTS (SELECT FROM pg_roles …)`. So it ran, granted nothing, and
      reported success. Verified 2026-10-16 against the deployed database:
      `pg_roles` held only Neon's own roles, and the first deployed dbt run said
      `marts SELECT granted to: none`.

      Supplying the passwords now cannot fix that, because that migration will
      never run again. Hence this one.

      ⚠️ **Generalisable: a grant guarded by `IF EXISTS` on its own grantee
      reports success when its subject is missing.** The guard is what makes the
      migration portable across environments, and it is also what makes the
      outcome unobservable. The pair needs a far-end assertion, not a
      conditional — which is why this migration RAISES when a password is
      supplied and the role still does not exist afterwards, and why
      `deployed_roles_test.exs` checks the privileges against the database
      rather than trusting this file.

      ## The grants are on the real schemas this time

      Every warehouse grant in the original migration targeted `wh` — the one
      schema dbt never writes to. dbt materialises into `staging`,
      `intermediate` and `marts` (`dbt/dbt_project.yml`), so `stacks_dbt` needs
      **CREATE** there, not merely CRUD on tables that do not exist yet.

      `wh` still gets USAGE + CREATE, deliberately: it is `profiles.yml`'s
      default target, so a model filed outside the three layer directories lands
      there, and the project's recorded preference is that such a mistake show
      up as rows in a schema nothing reads rather than as a permission error.
      The orphan sweep now covers `wh` too, so a stray relation is surfaced
      rather than permanent.

      ## What this deliberately does NOT do

      It does not switch the application's own connection to `stacks_app`.
      `docs/rls-design.md` applies `FORCE ROW LEVEL SECURITY` to every table, so
      connecting as a non-owner activates policies that have never been
      exercised against production data — a change with its own failure modes
      and its own validation, not a line in a grants migration. The app
      continues to connect as the database owner; the grants below make
      `stacks_app` correct for when that change is made.

      What it DOES change in practice is the nightly warehouse refresh, which
      connects as `stacks_dbt` and therefore proves these grants by using them.
  """
  use Ecto.Migration

  @app_role "stacks_app"
  @dbt_role "stacks_dbt"
  @readonly_role "stacks_readonly"

  # ⚠️ The password is interpolated into DDL, because `CREATE ROLE … PASSWORD`
  # cannot be parameterised — so the value is validated against a strict
  # alphabet first rather than escaped. The predecessor migration interpolated
  # it unchecked, which is a SQL-injection surface in a migration that runs as
  # the database owner.
  #
  # The alphabet excludes quotes and backslashes, so there is nothing to escape,
  # and the length floor keeps a careless value out of production.
  @password_pattern ~r/\A[A-Za-z0-9._~\-]{24,128}\z/

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    app_password = validated_password("STACKS_APP_DB_PASSWORD")
    dbt_password = validated_password("STACKS_DBT_DB_PASSWORD")

    ensure_login_role(@app_role, app_password)
    ensure_login_role(@dbt_role, dbt_password)
    ensure_nologin_role(@readonly_role)

    execute(grants_up(), grants_down())

    # The far-end assertion. A password was supplied, so the role must exist;
    # anything else means this migration silently did nothing, which is the
    # exact failure it was written to end.
    for {var, role} <- [
          {"STACKS_APP_DB_PASSWORD", @app_role},
          {"STACKS_DBT_DB_PASSWORD", @dbt_role}
        ] do
      if System.get_env(var), do: execute(assert_role_exists(role, var))
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute(grants_down())
  end

  defp validated_password(var) do
    case System.get_env(var) do
      nil ->
        nil

      "" ->
        raise """
        #{var} is set but empty.

        An empty password would create a login role that cannot be used and
        would read as "configured" to everything downstream. Unset it, or give
        it a real value.
        """

      password ->
        unless Regex.match?(@password_pattern, password) do
          raise """
          #{var} does not match the required shape.

          It must be 24-128 characters of [A-Za-z0-9._~-] only. The restriction
          is not stylistic: `CREATE ROLE ... PASSWORD` cannot be parameterised,
          so the value is interpolated into DDL that runs as the database owner,
          and an alphabet with no quotes or backslashes is what makes that safe.

          Generate one with: openssl rand -base64 48 | tr -dc 'A-Za-z0-9._~-' | head -c 48
          """
        end

        password
    end
  end

  # Idempotent in both directions: creates the role when absent, and resets the
  # password when present, so rotating a secret and re-running is the supported
  # path rather than a manual `ALTER ROLE` someone has to remember.
  defp ensure_login_role(_role, nil), do: :ok

  defp ensure_login_role(role, password) do
    execute(
      """
      DO $$ BEGIN
        IF EXISTS (SELECT FROM pg_roles WHERE rolname = '#{role}') THEN
          ALTER ROLE #{role} LOGIN PASSWORD '#{password}';
          RAISE NOTICE 'role #{role} already existed; password reset';
        ELSE
          CREATE ROLE #{role} LOGIN PASSWORD '#{password}';
          RAISE NOTICE 'role #{role} created';
        END IF;
      END $$;
      """,
      ""
    )
  end

  defp ensure_nologin_role(role) do
    execute(
      """
      DO $$ BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '#{role}') THEN
          CREATE ROLE #{role} NOLOGIN;
          RAISE NOTICE 'role #{role} created';
        END IF;
      END $$;
      """,
      ""
    )
  end

  defp assert_role_exists(role, var) do
    """
    DO $$ BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '#{role}') THEN
        RAISE EXCEPTION
          '#{var} was supplied but role #{role} does not exist after this migration — it granted nothing and would have reported success';
      END IF;
    END $$;
    """
  end

  # The grants remain `IF EXISTS`-guarded, because a developer database may
  # legitimately have only some of these roles. What changed is that the absence
  # is no longer unobservable: the assertion above fires when a password said a
  # role should be there, and the accompanying deployed test checks the
  # privileges themselves.
  defp grants_up do
    """
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = '#{@dbt_role}') THEN
        -- Reads the operational and audit schemas. SELECT only: dbt derives,
        -- it never writes back.
        GRANT USAGE ON SCHEMA op, audit TO #{@dbt_role};
        GRANT SELECT ON ALL TABLES IN SCHEMA op, audit TO #{@dbt_role};
        ALTER DEFAULT PRIVILEGES IN SCHEMA op GRANT SELECT ON TABLES TO #{@dbt_role};
        ALTER DEFAULT PRIVILEGES IN SCHEMA audit GRANT SELECT ON TABLES TO #{@dbt_role};

        -- Builds here. CREATE is the privilege the original grants omitted
        -- entirely, which is why `stacks_dbt` could not have materialised a
        -- relation even where the role existed.
        GRANT USAGE, CREATE ON SCHEMA staging, intermediate, marts, wh TO #{@dbt_role};
        GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES
          IN SCHEMA staging, intermediate, marts TO #{@dbt_role};
      END IF;

      IF EXISTS (SELECT FROM pg_roles WHERE rolname = '#{@app_role}') THEN
        -- CRUD on the operational schema, append-only on the audit trail.
        GRANT USAGE ON SCHEMA op TO #{@app_role};
        GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA op TO #{@app_role};
        ALTER DEFAULT PRIVILEGES IN SCHEMA op
          GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO #{@app_role};
        GRANT USAGE ON SCHEMA audit TO #{@app_role};
        GRANT INSERT ON ALL TABLES IN SCHEMA audit TO #{@app_role};
        REVOKE UPDATE, DELETE ON audit.audit_log FROM #{@app_role};

        -- Reads marts, not `wh`. The original granted SELECT on `wh`, which is
        -- empty by design, so the app could read nothing.
        GRANT USAGE ON SCHEMA marts TO #{@app_role};
        GRANT SELECT ON ALL TABLES IN SCHEMA marts TO #{@app_role};
      END IF;

      IF EXISTS (SELECT FROM pg_roles WHERE rolname = '#{@readonly_role}') THEN
        GRANT USAGE ON SCHEMA op, marts TO #{@readonly_role};
        GRANT SELECT ON ALL TABLES IN SCHEMA op, marts TO #{@readonly_role};
      END IF;
    END $$;
    """
  end

  defp grants_down do
    """
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = '#{@dbt_role}') THEN
        ALTER DEFAULT PRIVILEGES IN SCHEMA op REVOKE SELECT ON TABLES FROM #{@dbt_role};
        ALTER DEFAULT PRIVILEGES IN SCHEMA audit REVOKE SELECT ON TABLES FROM #{@dbt_role};
        REVOKE ALL ON ALL TABLES IN SCHEMA staging, intermediate, marts FROM #{@dbt_role};
        REVOKE ALL ON SCHEMA staging, intermediate, marts, wh FROM #{@dbt_role};
        REVOKE ALL ON ALL TABLES IN SCHEMA op, audit FROM #{@dbt_role};
        REVOKE USAGE ON SCHEMA op, audit FROM #{@dbt_role};
      END IF;

      IF EXISTS (SELECT FROM pg_roles WHERE rolname = '#{@app_role}') THEN
        ALTER DEFAULT PRIVILEGES IN SCHEMA op
          REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM #{@app_role};
        REVOKE ALL ON ALL TABLES IN SCHEMA op, audit, marts FROM #{@app_role};
        REVOKE USAGE ON SCHEMA op, audit, marts FROM #{@app_role};
      END IF;

      IF EXISTS (SELECT FROM pg_roles WHERE rolname = '#{@readonly_role}') THEN
        REVOKE ALL ON ALL TABLES IN SCHEMA op, marts FROM #{@readonly_role};
        REVOKE USAGE ON SCHEMA op, marts FROM #{@readonly_role};
      END IF;
    END $$;
    """
  end
end
