defmodule Core.Repo.Migrations.TreatAnEmptiedScopeTheSameAsAnUnsetOne do
  @moduledoc """
      `op.current_scope()` now refuses an EMPTY scope with the same named error
      it gives an unset one, and the deployed function no longer depends on a
      role default it may not be allowed to set.

      ⛔ **Why this exists: a deploy failed.** The preceding migration tried
      `ALTER ROLE stacks_app SET app.current_user_id = 'unset'`, and on a real
      database that aborted the release command:

          ERROR 42501 (insufficient_privilege)
          permission denied to set parameter "app.current_user_id"

      `ALTER ROLE … SET` on a custom parameter requires SUPERUSER. The deployed
      database owner is not one; a developer's local role is. So the statement
      worked everywhere it was tested and failed the first time it met the
      thing it was for — the same shape those notes had already warned about
      for `BYPASSRLS`, walked into one layer down.

      ## What the failure revealed, which is the useful part

      ⚠️ The role default was never load-bearing. Measured, with it absent:

          never set in this session        → current_setting(…, true) IS NULL
                                           → the named 42501 refusal
          set once and reverted            → current_setting(…, true) = ''
                                           → falls through to ''::uuid
                                           → ERROR invalid input syntax for type uuid

      Both refuse. The default only decided whether the second case named
      itself or arrived as a cast error. So the fix is to name it: treat `''`
      as unscoped, and the superuser dependency disappears rather than being
      worked around.

      ⚠️ A new migration rather than an edit to the one that defined the
      function, because that one has already run on local and CI databases and
      would never pick up a change — this project has the lesson on record.
      `CREATE OR REPLACE` means databases that ran the old version converge and
      a fresh one gets the right definition first time.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION op.current_scope() RETURNS uuid
      LANGUAGE plpgsql
      STABLE
    AS $$
    DECLARE
      scope text := current_setting('app.current_user_id', true);
    BEGIN
      -- ⚠️ Three states, one answer. NULL is a connection that has never been
      -- scoped; the empty string is one that was scoped and whose transaction
      -- ended, because SET LOCAL reverts to the parameter's default and an
      -- already-seen custom parameter defaults to ''; 'unset' is the role
      -- default where a superuser was available to set one. None of them is a
      -- user, and reading any of them as one would set a scope matching no row
      -- — every query then returning nothing while reporting success.
      IF scope IS NULL OR scope = '' OR scope = 'unset' THEN
        RAISE EXCEPTION
          'query on a row-level-secured table with no request scope set'
          USING ERRCODE = '42501',
                HINT = 'wrap the query in Stacks.Scope.with_user/2, or declare the worker scope';
      END IF;

      RETURN scope::uuid;
    END
    $$
    """)

    execute("GRANT EXECUTE ON FUNCTION op.current_scope() TO PUBLIC")
  end

  def down do
    # Back to the definition that required the role default to give a named
    # error on a reused connection.
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
  end
end
