defmodule Core.Repo.Migrations.AnswerTheThreeCrossUserQuestionsWithoutABroadExemption do
  @moduledoc """
      Three questions this application has always asked across users, and which
      per-user row-level scoping cannot answer.

      ⛔ **Each of them failed SILENTLY under the new policies** — the query
      succeeds and returns fewer rows — which is the one failure shape the
      scoping change exists to eliminate. Found by enumerating the call sites
      rather than by a test, because no test could see it: the test role is a
      superuser and bypasses row-level security entirely.

      1. **"Has either of these two users blocked the other?"** The predicate
         checks BOTH directions, so scoping to either party hides the other
         party's block row and a blocked pair becomes mutually visible. It is
         called from four sites in the application's primary authorisation gate,
         so this is a privacy regression introduced by a security change, in the
         gate rather than the backstop.

      2. **"Which users have this book on a wishlist?"** Read to notify someone
         that a book they wanted has become available. Inherently every user's
         wishlist, and private data.

      3. **"Who is offering these books to a good home?"** Rendered as
         marketplace labels next to search results.

      ## Two mechanisms, chosen per question rather than one for all three

      ⚠️ **(1) and (2) get a narrow `SECURITY DEFINER` function each.** One
      function, one answer — a boolean and a list of user ids. The function is
      owned by `op.rls_reader`, a role that **cannot log in** and therefore is
      not a credential anybody holds; it is only a function owner.

      ⛔ **And it does NOT use `BYPASSRLS`, which matters for more than taste.**
      `BYPASSRLS` can only be granted by a superuser, and the deployed database
      owner is not one — so a design resting on it would work locally and fail
      on the first real deploy. Measured instead: a `NOLOGIN` role with its own
      role-scoped `USING (true)` policy, owning a `SECURITY DEFINER` function,
      answers the cross-user question while a direct query as the blocked party
      still returns zero rows, with `rolbypassrls = false` throughout.

      ⚠️ **(3) gets a policy, not an exemption, because the data really is
      public.** A placement with `listing_status = 'active'` is a marketplace
      listing offered to strangers; saying so in a policy is more honest than
      routing a public read through a privileged function. The join also needs
      the `looking_for_home` shelf row, and exposing that discloses nothing:
      all five named shelves exist for every user, so its presence is true by
      construction — measured, 18 of 18 users.
  """

  use Ecto.Migration

  @cross_user_tables ~w(user_blocks bookshelves bookshelf_placements)

  def up do
    # ── The function owner: a role nobody can connect as ────────────────────
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rls_reader') THEN
        CREATE ROLE rls_reader NOLOGIN;
      END IF;
    END $$
    """)

    execute("GRANT USAGE ON SCHEMA op TO rls_reader")

    for table <- @cross_user_tables do
      execute("GRANT SELECT ON op.#{table} TO rls_reader")

      execute("DROP POLICY IF EXISTS #{table}_definer_read ON op.#{table}")

      execute("""
      CREATE POLICY #{table}_definer_read ON op.#{table}
        FOR SELECT TO rls_reader
        USING (true)
      """)
    end

    # ── (1) the block predicate, both directions, one bit ───────────────────
    #
    # ⚠️ `SET search_path` is not optional on a SECURITY DEFINER function: the
    # caller controls their own search_path, and without pinning it here a
    # caller could shadow `op` and have this run against their own tables with
    # the owner's privileges.
    execute("""
    CREATE OR REPLACE FUNCTION op.blocked_pair(a uuid, b uuid) RETURNS boolean
      LANGUAGE sql
      STABLE
      SECURITY DEFINER
      SET search_path = op, pg_temp
    AS $$
      SELECT EXISTS (
        SELECT 1 FROM op.user_blocks
         WHERE (blocker_id = a AND blocked_id = b)
            OR (blocker_id = b AND blocked_id = a)
      )
    $$
    """)

    # ── (2) who wants this book ─────────────────────────────────────────────
    #
    # Returns ids only. A caller that wants anything else about those users has
    # to ask for it through a path of its own, which keeps this from becoming a
    # general-purpose way to read other people's shelves.
    execute("""
    CREATE OR REPLACE FUNCTION op.wishlist_user_ids(wanted_book_id uuid)
      RETURNS TABLE (user_id uuid)
      LANGUAGE sql
      STABLE
      SECURITY DEFINER
      SET search_path = op, pg_temp
    AS $$
      SELECT DISTINCT bs.user_id
        FROM op.bookshelves bs
        JOIN op.bookshelf_placements p ON p.bookshelf_id = bs.id
       WHERE bs.name = 'wishlist'
         AND p.book_id = wanted_book_id
         AND p.removed_at IS NULL
    $$
    """)

    for fun <- ["op.blocked_pair(uuid, uuid)", "op.wishlist_user_ids(uuid)"] do
      execute("ALTER FUNCTION #{fun} OWNER TO rls_reader")
      execute("GRANT EXECUTE ON FUNCTION #{fun} TO stacks_app")
    end

    # ── (3) an active listing is public, and the policy says so ─────────────
    execute(
      "DROP POLICY IF EXISTS bookshelf_placements_active_listing ON op.bookshelf_placements"
    )

    execute("""
    CREATE POLICY bookshelf_placements_active_listing ON op.bookshelf_placements
      FOR SELECT
      USING (listing_status = 'active' AND removed_at IS NULL)
    """)

    execute("DROP POLICY IF EXISTS bookshelves_looking_for_home ON op.bookshelves")

    execute("""
    CREATE POLICY bookshelves_looking_for_home ON op.bookshelves
      FOR SELECT
      USING (name = 'looking_for_home')
    """)

    # ⚠️ Both arms of the new placement policy need an index or the OR they add
    # turns the read into a sequential scan — the same effect measured for the
    # platform-visibility arm.
    create_if_not_exists index(:bookshelf_placements, [:listing_status],
                           prefix: "op",
                           name: :bookshelf_placements_active_listing_idx,
                           where: "listing_status = 'active' AND removed_at IS NULL"
                         )

    create_if_not_exists index(:bookshelves, [:name],
                           prefix: "op",
                           name: :bookshelves_looking_for_home_idx,
                           where: "name = 'looking_for_home'"
                         )
  end

  def down do
    drop_if_exists index(:bookshelves, [:name],
                     prefix: "op",
                     name: :bookshelves_looking_for_home_idx
                   )

    drop_if_exists index(:bookshelf_placements, [:listing_status],
                     prefix: "op",
                     name: :bookshelf_placements_active_listing_idx
                   )

    execute("DROP POLICY IF EXISTS bookshelves_looking_for_home ON op.bookshelves")

    execute(
      "DROP POLICY IF EXISTS bookshelf_placements_active_listing ON op.bookshelf_placements"
    )

    execute("DROP FUNCTION IF EXISTS op.wishlist_user_ids(uuid)")
    execute("DROP FUNCTION IF EXISTS op.blocked_pair(uuid, uuid)")

    for table <- @cross_user_tables do
      execute("DROP POLICY IF EXISTS #{table}_definer_read ON op.#{table}")
      execute("REVOKE SELECT ON op.#{table} FROM rls_reader")
    end

    execute("REVOKE USAGE ON SCHEMA op FROM rls_reader")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rls_reader') THEN
        DROP ROLE rls_reader;
      END IF;
    END $$
    """)
  end
end
