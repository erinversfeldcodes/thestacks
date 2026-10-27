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
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    # ── The function owner: a role nobody can connect as ────────────────────
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rls_reader') THEN
        CREATE ROLE rls_reader NOLOGIN;
      END IF;
    END $$
    """)

    # ⚠️ USAGE to read, and CREATE because of a rule that is easy to miss:
    # transferring ownership of a function requires the NEW OWNER to hold CREATE
    # on the schema that function lives in. Without it the deploy aborts with
    # `permission denied for schema op` on the `ALTER FUNCTION … OWNER TO`
    # below — measured, on the release command of a real deploy.
    #
    # ⛔ Granting CREATE on `op` to a role is worth justifying rather than
    # waving through. `rls_reader` is NOLOGIN, so the only ways to act as it are
    # `SET ROLE` — which needs membership, held only by the migrating owner,
    # who can already create in `op` directly — and the two definer functions
    # below, which are fixed SQL with no dynamic execution. So this adds no
    # capability to anybody who did not already have it.
    #
    # ⚠️ The narrower alternative was a schema of its own for these functions,
    # rejected only because it renames them at four call sites and in the scope
    # gate; if a third definer function ever appears, that trade flips.
    execute("GRANT USAGE, CREATE ON SCHEMA op TO rls_reader")

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

    # ⚠️ `ALTER FUNCTION … OWNER TO` requires the current role to be a MEMBER of
    # the role it is handing ownership to — creating a role does not by itself
    # confer that everywhere. Granted explicitly so the transfer below does not
    # depend on which Postgres version's implicit-admin rules apply.
    execute("""
    DO $$
    BEGIN
      EXECUTE format('GRANT rls_reader TO %I', current_user);
    EXCEPTION
      WHEN insufficient_privilege THEN
        RAISE NOTICE 'could not grant rls_reader to %, relying on implicit admin', current_user;
    END $$
    """)

    for fun <- ["op.blocked_pair(uuid, uuid)", "op.wishlist_user_ids(uuid)"] do
      # ⛔ NOT swallowed if it fails. A function left owned by the migrating role
      # still works — that role can read every row — but it works by being
      # broadly privileged rather than by the narrow grant this design rests on,
      # and on a deployed database the owner holds BYPASSRLS. A deploy that
      # stops here and says so is better than one that quietly ships a
      # cross-user read with no boundary around it.
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
    #
    # ⛔ THE TWO INDEXES ARE BUILT BY THE SUCCESSOR MIGRATION, CONCURRENTLY.
    # They were created here, in this transaction, which takes a lock against
    # WRITES on `op.bookshelf_placements` and `op.bookshelves` for the whole
    # build — both tables on the request path, and `bookshelf_placements` is
    # written by every shelving action. A concurrent build needs its own
    # transaction (`@disable_ddl_transaction`), which the policies and functions
    # above cannot share, so the index work moved out rather than the policy
    # work.
    #
    # ⚖️ Ordering is safe because the dependency is PERFORMANCE, not
    # correctness: the policies above are enforced with or without the indexes,
    # and until the successor runs the reads they govern are merely slow.
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    # ⚠️ The two policy-supporting indexes are dropped by the successor
    # migration's `down`, since that is where they are created. Dropping them
    # here as well would be harmless on a full rollback and wrong on a partial
    # one: rolling back only this migration would remove indexes the successor
    # still believes it owns.
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

    execute("REVOKE USAGE, CREATE ON SCHEMA op FROM rls_reader")

    # ⛔ A ROLE IS CLUSTER-WIDE, SO THIS DROP CANNOT BE A PER-DATABASE DECISION.
    #
    # MEASURED, and it is why `mix ecto.rollback --all` — the reversibility
    # check at the end of scripts/test-elixir.sh — failed on this migration:
    #
    #     ERROR 2BP01 (dependent_objects_still_exist)
    #     role "rls_reader" cannot be dropped because some objects depend on it
    #     16 objects in database stacks_dev
    #
    # The rollback was running against `stacks_test`. Every statement above
    # released everything this migration tied to the role IN THIS DATABASE —
    # verified, zero rows left in `pg_shdepend` at this point — and the DROP
    # still failed, because `pg_shdepend` is a SHARED catalogue and `stacks_dev`
    # had the same functions and grants from its own copy of this migration.
    #
    # ⚠️ So the failure had nothing to do with this migration's own
    # completeness, and no amount of extra REVOKEs here could have fixed it. Any
    # cluster holding two Stacks databases reproduces it: a developer's dev plus
    # test, a CI machine with both, a staging cluster beside a preview branch.
    #
    # ⚖️ Swallowing `dependent_objects_still_exist` is the same answer
    # `20260305000020` reached for `stacks_app`, `stacks_dbt` and
    # `stacks_readonly`, and it is right for the same reason: the role is
    # NOLOGIN and holds no privilege once the revokes above have run, so leaving
    # it behind grants nobody anything. A rollback that cannot complete is a
    # worse outcome than a tidy-up that cannot finish.
    #
    # ⚠️ What is NOT swallowed is anything else. A permissions error, a missing
    # schema, a syntax error still aborts — only the one condition that is
    # provably not this database's business is caught.
    execute("""
    DO $$
    BEGIN
      BEGIN
        DROP ROLE IF EXISTS rls_reader;
      EXCEPTION WHEN dependent_objects_still_exist THEN
        RAISE NOTICE
          'rls_reader kept: another database in this cluster still owns objects as it. '
          'It is NOLOGIN and every grant made here has been revoked.';
      END;
    END $$
    """)
  end
end
