defmodule Core.Repo.Migrations.AnswerTheThreeQuestionsAScopeCannot do
  @moduledoc """
      Three more questions that per-user scoping cannot answer, each given the
      narrowest mechanism that answers it — and one existing function narrowed.

      ⛔ All three were found by connecting as the runtime role and letting the
      policy refuse, after a module-granular source gate reported the codebase
      clean. The gate's allowlist held eight entries; seven carried reasons that
      were factually false, and each of these three sat behind one of them.

      ## 1. `op.platform_row_counts()` — the totals, not a reader's slice

      The public transparency page publishes how many books are shelved
      platform-wide, and the operator dashboard counts bookshelves and
      placements. Both are **aggregates over every row**, so no per-user scope is
      correct and the anonymous scope is wrong in a worse way: it returns the
      count of *publicly visible* rows, which is a plausible smaller number that
      a reader cannot tell from the truth. Measured on this database: 24 of 90
      bookshelves, and 0 of 220 placements.

      ⚠️ A silently-smaller count on a transparency page is the exact failure
      this project has on record from its metrics pipeline — structurally
      complete, reporting a number nobody could tell was wrong.

      Returns one row of integers. No row data escapes, which is what keeps it
      in the same family as the boolean and the id-list already here rather than
      being a general-purpose read.

      ## 2. `op.placement_owner(uuid)` — whose placement is this?

      An event subscriber receives a placement id and must regenerate that
      user's feed. It cannot scope to the user because finding the user IS the
      question. Structurally identical to the correction helper that answers the
      same question for an edition, so it gets the same shape.

      ⛔ The caller also swallowed the refusal. A function-level `rescue _ -> nil`
      turned `42501` into a `nil` user id, and the handler's `if user_id do`
      then skipped the enqueue and returned `:ok`. Feed regeneration failed
      completely, silently, with no log line and no Oban retry — the worst
      failure shape in the review set, and invisible to any test because the
      test role bypasses row-level security.

      ## 3. `op.blocked_pair/2` narrowed — the enumeration was the leak

      The function answers "has either of these two blocked the other", and its
      safety argument was that one bit cannot leak much. That argument is wrong
      in a way worth recording: **the answer is one bit and the enumeration is
      the leak.** With EXECUTE granted, the runtime role recovers every edge of
      the block graph in n² calls — safety-relevant data about people who are
      not the caller.

      ⚠️ It must NOT simply refuse when unscoped. Both call sites legitimately
      run with no scope on public, unauthenticated profile reads, so a
      scope-refusing variant converts a privacy check into a 5xx on exactly
      those paths. The guard is therefore conditional: refuse only when a scope
      IS set and neither argument is the scoped user. Both call sites pass the
      viewer as the first argument, so nothing breaks, and a compromised
      runtime role can only ask about pairs it belongs to.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    # ── 1. platform-wide totals ─────────────────────────────────────────────
    execute("""
    CREATE OR REPLACE FUNCTION op.platform_row_counts()
      RETURNS TABLE (bookshelves bigint, placements bigint, active_placements bigint)
      LANGUAGE sql
      STABLE
      SECURITY DEFINER
      SET search_path = op, pg_temp
    AS $$
      SELECT (SELECT count(*) FROM op.bookshelves),
             (SELECT count(*) FROM op.bookshelf_placements),
             (SELECT count(*) FROM op.bookshelf_placements WHERE removed_at IS NULL)
    $$
    """)

    # ── 2. the owner of one placement ───────────────────────────────────────
    execute("""
    CREATE OR REPLACE FUNCTION op.placement_owner(placement_id uuid) RETURNS uuid
      LANGUAGE sql
      STABLE
      SECURITY DEFINER
      SET search_path = op, pg_temp
    AS $$
      SELECT bs.user_id
        FROM op.bookshelf_placements p
        JOIN op.bookshelves bs ON bs.id = p.bookshelf_id
       WHERE p.id = placement_id
    $$
    """)

    # ⚠️ Ownership transfer and the grant list, in the same shape the preceding
    # migration established: REVOKE from PUBLIC first, because CREATE FUNCTION
    # grants EXECUTE to PUBLIC by default and leaving that in place makes every
    # named grant below decorative.
    for fun <- ["op.platform_row_counts()", "op.placement_owner(uuid)"] do
      execute("ALTER FUNCTION #{fun} OWNER TO rls_reader")
      execute("REVOKE ALL ON FUNCTION #{fun} FROM PUBLIC")
      execute("GRANT EXECUTE ON FUNCTION #{fun} TO stacks_app")
    end

    # ── 3. narrow blocked_pair ──────────────────────────────────────────────
    execute("""
    CREATE OR REPLACE FUNCTION op.blocked_pair(a uuid, b uuid) RETURNS boolean
      LANGUAGE plpgsql
      STABLE
      SECURITY DEFINER
      SET search_path = op, pg_temp
    AS $$
    DECLARE
      scope text := current_setting('app.current_user_id', true);
    BEGIN
      -- Refuse only when a real user scope is present and this question is
      -- about two other people. An absent scope, an emptied one, or the
      -- anonymous sentinel all fall through: the public profile path asks this
      -- question with no viewer and must keep working.
      IF scope IS NOT NULL AND scope <> '' AND scope <> 'unset' AND scope <> 'anonymous' THEN
        IF a <> scope::uuid AND b <> scope::uuid THEN
          RAISE EXCEPTION
            'blocked_pair asked about two users, neither of whom is the scoped user'
            USING ERRCODE = '42501',
                  HINT = 'pass the viewer as one of the two arguments';
        END IF;
      END IF;

      RETURN EXISTS (
        SELECT 1 FROM op.user_blocks
         WHERE (blocker_id = a AND blocked_id = b)
            OR (blocker_id = b AND blocked_id = a)
      );
    END
    $$
    """)

    execute("ALTER FUNCTION op.blocked_pair(uuid, uuid) OWNER TO rls_reader")
    execute("REVOKE ALL ON FUNCTION op.blocked_pair(uuid, uuid) FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION op.blocked_pair(uuid, uuid) TO stacks_app")
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    execute("DROP FUNCTION IF EXISTS op.placement_owner(uuid)")
    execute("DROP FUNCTION IF EXISTS op.platform_row_counts()")

    # Back to the un-narrowed pair predicate, PUBLIC grant still revoked.
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

    execute("ALTER FUNCTION op.blocked_pair(uuid, uuid) OWNER TO rls_reader")
    execute("REVOKE ALL ON FUNCTION op.blocked_pair(uuid, uuid) FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION op.blocked_pair(uuid, uuid) TO stacks_app")
  end
end
