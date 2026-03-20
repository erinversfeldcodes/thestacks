defmodule Core.Repo.Migrations.EnableRlsPolicies do
  @moduledoc """
  Enables Row-Level Security policies on user-data tables in the op schema.

  Policies use `current_setting('app.current_user_id', true)` with a NULL
  guard so that sessions without the variable set (migrations, test sandbox)
  are not blocked. In production the Phoenix pool sets this via
  `SET LOCAL app.current_user_id = '<uuid>'` at the start of each transaction.

  See docs/rls-design.md for the full policy rationale.
  """

  use Ecto.Migration

  def up do
    # bookshelves
    execute("ALTER TABLE op.bookshelves ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE op.bookshelves FORCE ROW LEVEL SECURITY")

    execute("""
    CREATE POLICY bookshelves_owner ON op.bookshelves
      USING (
        current_setting('app.current_user_id', true) IS NULL
        OR user_id = current_setting('app.current_user_id', true)::uuid
      )
      WITH CHECK (
        current_setting('app.current_user_id', true) IS NULL
        OR user_id = current_setting('app.current_user_id', true)::uuid
      )
    """)

    execute("""
    CREATE POLICY bookshelves_platform_select ON op.bookshelves
      FOR SELECT
      USING (visibility = 'platform')
    """)

    # bookshelf_placements
    execute("ALTER TABLE op.bookshelf_placements ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE op.bookshelf_placements FORCE ROW LEVEL SECURITY")

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

    execute("""
    CREATE POLICY bookshelf_placements_platform_select ON op.bookshelf_placements
      FOR SELECT
      USING (
        visibility = 'platform'
        AND bookshelf_id IN (
          SELECT id FROM op.bookshelves WHERE visibility = 'platform'
        )
      )
    """)

    # user_blocks
    execute("ALTER TABLE op.user_blocks ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE op.user_blocks FORCE ROW LEVEL SECURITY")

    execute("""
    CREATE POLICY user_blocks_owner ON op.user_blocks
      USING (
        current_setting('app.current_user_id', true) IS NULL
        OR blocker_id = current_setting('app.current_user_id', true)::uuid
      )
      WITH CHECK (
        current_setting('app.current_user_id', true) IS NULL
        OR blocker_id = current_setting('app.current_user_id', true)::uuid
      )
    """)

    # visibility_grants
    execute("ALTER TABLE op.visibility_grants ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE op.visibility_grants FORCE ROW LEVEL SECURITY")

    execute("""
    CREATE POLICY visibility_grants_granter ON op.visibility_grants
      USING (
        current_setting('app.current_user_id', true) IS NULL
        OR granted_by_id = current_setting('app.current_user_id', true)::uuid
      )
      WITH CHECK (
        current_setting('app.current_user_id', true) IS NULL
        OR granted_by_id = current_setting('app.current_user_id', true)::uuid
      )
    """)

    execute("""
    CREATE POLICY visibility_grants_grantee_select ON op.visibility_grants
      FOR SELECT
      USING (
        current_setting('app.current_user_id', true) IS NULL
        OR granted_to_id = current_setting('app.current_user_id', true)::uuid
      )
    """)
  end

  def down do
    execute("DROP POLICY IF EXISTS bookshelves_owner ON op.bookshelves")
    execute("DROP POLICY IF EXISTS bookshelves_platform_select ON op.bookshelves")
    execute("ALTER TABLE op.bookshelves DISABLE ROW LEVEL SECURITY")

    execute("DROP POLICY IF EXISTS bookshelf_placements_owner ON op.bookshelf_placements")

    execute(
      "DROP POLICY IF EXISTS bookshelf_placements_platform_select ON op.bookshelf_placements"
    )

    execute("ALTER TABLE op.bookshelf_placements DISABLE ROW LEVEL SECURITY")

    execute("DROP POLICY IF EXISTS user_blocks_owner ON op.user_blocks")
    execute("ALTER TABLE op.user_blocks DISABLE ROW LEVEL SECURITY")

    execute("DROP POLICY IF EXISTS visibility_grants_granter ON op.visibility_grants")
    execute("DROP POLICY IF EXISTS visibility_grants_grantee_select ON op.visibility_grants")
    execute("ALTER TABLE op.visibility_grants DISABLE ROW LEVEL SECURITY")
  end
end
