defmodule Core.Repo.Migrations.MakeTheRowLevelPoliciesRefuseAnUnscopedQuery do
  @moduledoc """
      Replaces the `IS NULL OR` short-circuit in all seven row-level policies
      with a single function that RAISES when no request scope is set.

      ⛔ **The policies this replaces permitted every row, and were
      non-deterministic about it.** Measured on 2026-10-20:

          fresh connection, the GUC never set
            → current_setting('app.current_user_id', true) IS NULL = true
            → the short-circuit fires and the policy permits EVERY row

          the same connection after any transaction has SET LOCAL it,
          including one that ROLLED BACK
            → current_setting('app.current_user_id', true) = ''
            → IS NULL is false, the OR branch evaluates ''::uuid
            → ERROR: invalid input syntax for type uuid: ""

      `SET LOCAL` reverts the GUC to its default, and once a custom GUC has been
      set in a session its default is the empty string rather than unset. So on
      a pooled connection the same unscoped query either granted every row or
      raised a 500, decided by which connection served it. That was latent only
      because nothing ever set the GUC; it would have detonated on the first
      commit that scoped anything.

      ⚠️ Every decision here was measured rather than reasoned about, and three
      of those measurements are worth repeating at the point of change because
      each one rules out the shape somebody would otherwise reach for:

      1. **The function takes NO arguments and returns the scope.** Measured on
         50,000 rows with an index on `user_id`:
         `USING (user_id = op.current_scope())` plans a Bitmap Index Scan, while
         `USING (op.scope_allows(user_id))` — the obvious way to centralise the
         rule — plans a Seq Scan, because a function taking the row's value
         cannot be used as an index condition.

      2. **A system exemption is a role-scoped policy, never a value in the
         policy body.** `USING (op.current_scope() = <sentinel> OR user_id = ...)`
         also plans a Seq Scan, *even when scoped to a real user*. So `stacks_dbt`
         and `stacks_readonly` get their own `USING (true)` policies, which apply
         only when `current_user` matches and therefore leave the runtime role's
         plan with one indexable qual.

      3. **The role default is what makes the refusal deterministic.** A
         role-level default is inherited at login, and `SET LOCAL` reverts to
         *that* value rather than to the empty string — so an unscoped query
         raises identically on a fresh connection and on one that has already
         served a scoped request.

      ⚠️ The two `platform_select` policies keep their shape and reference no
      scope, deliberately: platform-visible rows are readable by any signed-in
      reader, which is the product's own rule and not something enforcement
      should quietly narrow.
  """

  use Ecto.Migration

  # ⚠️ Not in a transaction: `CREATE INDEX CONCURRENTLY` cannot run inside one,
  # and these four indexes are what keep the policy predicates off a sequential
  # scan. The policy swap itself is idempotent per statement.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # ── The one place the rule lives ────────────────────────────────────────
    #
    # ⚠️ Raises rather than returning NULL. Returning NULL would make every
    # comparison NULL and the query would quietly yield zero rows — which reads
    # to a user as "you have nothing" and to a monitor as a fast, healthy
    # response. The raise is a 5xx, which the deploy's SLO gate can see and roll
    # back on; silence is the one failure shape nothing catches.
    execute("""
    CREATE OR REPLACE FUNCTION op.current_scope() RETURNS uuid
      LANGUAGE plpgsql
      STABLE
    AS $$
    BEGIN
      IF current_setting('app.current_user_id', true) IS NULL
         OR current_setting('app.current_user_id', true) = 'unset' THEN
        RAISE EXCEPTION
          'query on a row-level-secured table with no request scope set'
          USING ERRCODE = '42501',
                HINT = 'wrap the query in Stacks.Scope.with_user/2, or declare the worker scope';
      END IF;

      RETURN current_setting('app.current_user_id')::uuid;
    END
    $$
    """)

    execute("GRANT EXECUTE ON FUNCTION op.current_scope() TO stacks_app")

    # ── The runtime role can never be "unset" ───────────────────────────────
    #
    # A deliberately non-UUID default, so the unscoped case is a cast failure
    # with the function's own message rather than a silent NULL.
    #
    # ⚠️ Guarded on the role existing: `stacks_app` is created by an earlier
    # migration only when its password is in the environment, so a developer
    # database may legitimately not have it.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stacks_app') THEN
        EXECUTE 'ALTER ROLE stacks_app SET app.current_user_id = ''unset''';
      END IF;
    END $$
    """)

    # ── The owner policies, reduced to one indexable equality ───────────────
    execute("DROP POLICY IF EXISTS bookshelves_owner ON op.bookshelves")

    execute("""
    CREATE POLICY bookshelves_owner ON op.bookshelves
      USING (user_id = op.current_scope())
      WITH CHECK (user_id = op.current_scope())
    """)

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

    execute("DROP POLICY IF EXISTS user_blocks_owner ON op.user_blocks")

    execute("""
    CREATE POLICY user_blocks_owner ON op.user_blocks
      USING (blocker_id = op.current_scope())
      WITH CHECK (blocker_id = op.current_scope())
    """)

    execute("DROP POLICY IF EXISTS visibility_grants_granter ON op.visibility_grants")

    execute("""
    CREATE POLICY visibility_grants_granter ON op.visibility_grants
      USING (granted_by_id = op.current_scope())
      WITH CHECK (granted_by_id = op.current_scope())
    """)

    execute("DROP POLICY IF EXISTS visibility_grants_grantee_select ON op.visibility_grants")

    execute("""
    CREATE POLICY visibility_grants_grantee_select ON op.visibility_grants
      FOR SELECT
      USING (granted_to_id = op.current_scope())
    """)

    # ── The warehouse and read-only exemptions ──────────────────────────────
    #
    # ⛔ Without these the first nightly dbt refresh RAISES. Measured:
    # `stacks_dbt` and `stacks_readonly` are both `rolsuper = false,
    # rolbypassrls = false`, so FORCE ROW LEVEL SECURITY applies to them, and
    # five staging models read these four tables — `stg_bookshelves`,
    # `stg_bookshelf_placements`, `stg_bookshelf_placement_history`,
    # `stg_user_blocks`, `stg_visibility_grants`. Today the NULL short-circuit
    # is the only reason the warehouse sees any rows at all.
    #
    # ⚠️ Declarative on purpose: the exemption is visible in `pg_policies`,
    # where a reviewer can audit who may read across users, rather than being a
    # sentinel value an application author has to remember.
    for table <- ~w(bookshelves bookshelf_placements user_blocks visibility_grants) do
      execute("DROP POLICY IF EXISTS #{table}_warehouse_read ON op.#{table}")

      execute("""
      DO $$
      BEGIN
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stacks_dbt')
           AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stacks_readonly') THEN
          EXECUTE 'CREATE POLICY #{table}_warehouse_read ON op.#{table} ' ||
                  'FOR SELECT TO stacks_dbt, stacks_readonly USING (true)';
        END IF;
      END $$
      """)
    end

    # ── Keep the policy predicates off a sequential scan ────────────────────
    #
    # ⚠️ Measured, and the reason is not obvious. Postgres combines PERMISSIVE
    # policies with OR, so a SELECT on `bookshelves` evaluates
    # `user_id = op.current_scope() OR visibility = 'platform'`. With only
    # `user_id` indexed that plans a Seq Scan — but with BOTH columns indexed
    # the planner builds a BitmapOr of two index scans. Partial indexes, because
    # the second arm only ever asks for the platform rows.
    #
    # The two `visibility_grants` columns have no usable index at all today:
    # `granted_by_id` has none, and `granted_to_id` is the third column of a
    # composite unique index, so neither owner predicate could use one.
    #
    # ⚠️ This is a pre-existing seq scan rather than one this change
    # introduces — the current policies already OR a second permissive policy
    # for SELECT. It is fixed here because enforcement should not inherit it,
    # and because `bookshelves_p95_ms` carries a 500 ms SLO threshold.
    create_if_not_exists index(:bookshelves, [:visibility],
                           prefix: "op",
                           name: :bookshelves_platform_visible_idx,
                           where: "visibility = 'platform'",
                           concurrently: true
                         )

    create_if_not_exists index(:bookshelf_placements, [:visibility],
                           prefix: "op",
                           name: :bookshelf_placements_platform_visible_idx,
                           where: "visibility = 'platform'",
                           concurrently: true
                         )

    create_if_not_exists index(:visibility_grants, [:granted_by_id],
                           prefix: "op",
                           name: :visibility_grants_granted_by_id_idx,
                           concurrently: true
                         )

    create_if_not_exists index(:visibility_grants, [:granted_to_id],
                           prefix: "op",
                           name: :visibility_grants_granted_to_id_idx,
                           concurrently: true
                         )
  end

  def down do
    # ⚠️ Restores the short-circuit, which means restoring the defect: the
    # policies permit every row again. That is the correct `down` — a rollback
    # must return the database to the state the previous release expects, and
    # the previous release does not set the GUC. The application half must roll
    # back with it.
    for {table, name, predicate} <- [
          {"bookshelves", "bookshelves_owner", "user_id"},
          {"user_blocks", "user_blocks_owner", "blocker_id"},
          {"visibility_grants", "visibility_grants_granter", "granted_by_id"}
        ] do
      execute("DROP POLICY IF EXISTS #{name} ON op.#{table}")

      execute("""
      CREATE POLICY #{name} ON op.#{table}
        USING (
          current_setting('app.current_user_id', true) IS NULL
          OR #{predicate} = current_setting('app.current_user_id', true)::uuid
        )
        WITH CHECK (
          current_setting('app.current_user_id', true) IS NULL
          OR #{predicate} = current_setting('app.current_user_id', true)::uuid
        )
      """)
    end

    execute("DROP POLICY IF EXISTS bookshelf_placements_owner ON op.bookshelf_placements")

    execute("""
    CREATE POLICY bookshelf_placements_owner ON op.bookshelf_placements
      USING (
        current_setting('app.current_user_id', true) IS NULL
        OR bookshelf_id IN (
          SELECT id FROM op.bookshelves
          WHERE user_id = current_setting('app.current_user_id', true)::uuid
        )
      )
      WITH CHECK (
        current_setting('app.current_user_id', true) IS NULL
        OR bookshelf_id IN (
          SELECT id FROM op.bookshelves
          WHERE user_id = current_setting('app.current_user_id', true)::uuid
        )
      )
    """)

    execute("DROP POLICY IF EXISTS visibility_grants_grantee_select ON op.visibility_grants")

    execute("""
    CREATE POLICY visibility_grants_grantee_select ON op.visibility_grants
      FOR SELECT
      USING (
        current_setting('app.current_user_id', true) IS NULL
        OR granted_to_id = current_setting('app.current_user_id', true)::uuid
      )
    """)

    for table <- ~w(bookshelves bookshelf_placements user_blocks visibility_grants) do
      execute("DROP POLICY IF EXISTS #{table}_warehouse_read ON op.#{table}")
    end

    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stacks_app') THEN
        EXECUTE 'ALTER ROLE stacks_app RESET app.current_user_id';
      END IF;
    END $$
    """)

    execute("DROP FUNCTION IF EXISTS op.current_scope()")

    drop_if_exists index(:bookshelves, [:visibility],
                     prefix: "op",
                     name: :bookshelves_platform_visible_idx,
                     concurrently: true
                   )

    drop_if_exists index(:bookshelf_placements, [:visibility],
                     prefix: "op",
                     name: :bookshelf_placements_platform_visible_idx,
                     concurrently: true
                   )

    drop_if_exists index(:visibility_grants, [:granted_by_id],
                     prefix: "op",
                     name: :visibility_grants_granted_by_id_idx,
                     concurrently: true
                   )

    drop_if_exists index(:visibility_grants, [:granted_to_id],
                     prefix: "op",
                     name: :visibility_grants_granted_to_id_idx,
                     concurrently: true
                   )
  end
end
