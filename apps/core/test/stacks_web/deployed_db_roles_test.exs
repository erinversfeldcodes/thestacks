defmodule StacksWeb.DeployedDbRolesTest do
  @moduledoc """
      LIVE-STACK assertion that the least-privilege roles exist and hold the
      privileges the migrations claim to grant them.

      This exists because the claim was false everywhere deployed, for months,
      while every gate stayed green. `20260305000020_create_db_roles.exs`
      creates a role only when `STACKS_*_DB_PASSWORD` is in the environment, the
      deploy set neither, and every grant in it is wrapped in
      `IF EXISTS (SELECT FROM pg_roles …)`. So the migration ran, granted
      nothing, and succeeded. `pg_roles` on the deployed database held only
      Neon's own roles, and the first dbt run there reported
      `marts SELECT granted to: none`.

      ⚠️ **A grant guarded by `IF EXISTS` on its grantee reports success when
      its subject is missing.** The guard is what makes the migration portable;
      it is also what makes the outcome unobservable. That pair cannot be fixed
      with a better conditional — it needs an assertion at the far end, against
      the database, which is this file.

      Skips locally, like the other deployed-only modules: the protected asset
      is the real database behind a preview or production stack, and a local
      sandbox proves nothing about it.
  """

  use ExUnit.Case, async: false

  @moduletag :deployed_only

  @db_url System.get_env("DATABASE_URL")

  if @db_url in [nil, ""] do
    @moduletag skip: "DATABASE_URL not set — a deployed database is required"
  end

  setup do
    # ⛔ Refuses a LOCAL DATABASE_URL rather than failing somewhere downstream.
    # The skip above fires only when the variable is UNSET, and this repository's
    # `.env` sets it to localhost.
    #
    # ⚠️ Without this the run was still fail-closed, but only by accident: the
    # connection below forces SSL and a default local Postgres rejects it, so the
    # suite died on a Postgrex SSL error that says nothing about the real
    # mistake. On a machine with local SSL enabled it would connect instead — and
    # a sandbox has all three roles, while staging has none of them, so passing
    # there would distinguish nothing.
    Core.DeployedTarget.require_deployed!("DATABASE_URL")

    uri = URI.parse(System.get_env("DATABASE_URL"))
    [user, pass] = String.split(uri.userinfo || "", ":", parts: 2)
    database = uri.path |> String.trim_leading("/") |> String.split("?") |> hd()

    # `start_supervised!`, not `Postgrex.start_link` plus an `on_exit` stop.
    #
    # The sibling deployed test uses the latter, and it does not work here: the
    # connection is LINKED to the test process, so it is already terminating by
    # the time `on_exit` runs in its own process, and the `GenServer.stop/1`
    # races it — every one of these tests failed with
    # `(EXIT) exited in: :sys.terminate(...) ** (EXIT) shutdown` while its
    # assertions had all passed. A teardown crash is reported identically to a
    # failed assertion, which is a bad way to learn anything.
    #
    # Letting ExUnit own the lifecycle removes the race entirely.
    conn =
      start_supervised!({
        Postgrex,
        # `ssl: [...]`, not `ssl: true` + `ssl_opts:` — Postgrex 0.22 ignores
        # the older pair and attempts the connection without TLS, which Neon
        # refuses with "ssl not available".
        hostname: uri.host,
        port: uri.port || 5432,
        username: user,
        password: pass,
        database: database,
        ssl: [verify: :verify_none]
      })

    {:ok, conn: conn}
  end

  defp scalar(conn, sql, params \\ []) do
    %Postgrex.Result{rows: [[value]]} = Postgrex.query!(conn, sql, params)
    value
  end

  describe "the least-privilege roles" do
    test "all three exist", %{conn: conn} do
      present =
        scalar(
          conn,
          "SELECT coalesce(array_agg(rolname ORDER BY rolname), '{}') FROM pg_roles " <>
            "WHERE rolname IN ('stacks_app', 'stacks_dbt', 'stacks_readonly')"
        )

      assert present == ["stacks_app", "stacks_dbt", "stacks_readonly"],
             "the deployed database is missing least-privilege roles: got " <>
               "#{inspect(present)}. The migrations grant to these roles behind " <>
               "`IF EXISTS`, so their absence is silent — every warehouse grant is inert " <>
               "and the refresh runs as the database owner. Set STACKS_APP_DB_PASSWORD and " <>
               "STACKS_DBT_DB_PASSWORD on the deploy and re-run migrations."
    end

    test "stacks_dbt can read the operational and audit schemas", %{conn: conn} do
      for {schema, table} <- [{"op", "op.users"}, {"audit", "audit.audit_log"}] do
        assert scalar(conn, "SELECT has_schema_privilege('stacks_dbt', $1, 'USAGE')", [schema]),
               "stacks_dbt has no USAGE on #{schema}"

        assert scalar(conn, "SELECT has_table_privilege('stacks_dbt', $1, 'SELECT')", [table]),
               "stacks_dbt cannot SELECT #{table} — dbt's staging models read it"
      end
    end

    test "stacks_dbt cannot write to the operational schema", %{conn: conn} do
      # The point of the role. dbt derives; it must never be able to write back,
      # and a grant that accidentally included INSERT would otherwise be
      # invisible — the build would simply keep working.
      for privilege <- ~w(INSERT UPDATE DELETE) do
        refute scalar(conn, "SELECT has_table_privilege('stacks_dbt', 'op.users', $1)", [
                 privilege
               ]),
               "stacks_dbt holds #{privilege} on op.users — the warehouse role must be read-only " <>
                 "against the operational schema"
      end
    end

    test "stacks_dbt can CREATE in each warehouse schema", %{conn: conn} do
      # CREATE, specifically. The original grants gave CRUD on tables in `wh`
      # and CREATE on nothing at all, so the role could not have materialised a
      # relation anywhere — which is why asserting USAGE alone would miss it.
      for schema <- ~w(staging intermediate marts) do
        assert scalar(conn, "SELECT has_schema_privilege('stacks_dbt', $1, 'CREATE')", [schema]),
               "stacks_dbt cannot CREATE in #{schema} — it builds there, so it cannot run"
      end
    end

    test "the reader roles can select the marts but not the staging layers", %{conn: conn} do
      # `staging` and `intermediate` carry columns the warehouse rules keep away
      # from readers — `stg_users.email`, `stg_post_comments.body` — so the
      # asymmetry is the contract, not an oversight.
      for role <- ~w(stacks_app stacks_readonly) do
        assert scalar(conn, "SELECT has_schema_privilege($1, 'marts', 'USAGE')", [role]),
               "#{role} has no USAGE on marts"

        for schema <- ~w(staging intermediate) do
          refute scalar(conn, "SELECT has_schema_privilege($1, $2, 'USAGE')", [role, schema]),
                 "#{role} has USAGE on #{schema}, which projects personal free text " <>
                   "(stg_users.email, stg_post_comments.body) that readers must not reach"
        end
      end
    end

    test "stacks_app cannot rewrite the audit trail", %{conn: conn} do
      assert scalar(
               conn,
               "SELECT has_table_privilege('stacks_app', 'audit.audit_log', 'INSERT')"
             ),
             "stacks_app cannot append to the audit trail"

      for privilege <- ~w(UPDATE DELETE) do
        refute scalar(
                 conn,
                 "SELECT has_table_privilege('stacks_app', 'audit.audit_log', $1)",
                 [privilege]
               ),
               "stacks_app holds #{privilege} on audit.audit_log — the trail is append-only"
      end
    end
  end
end
