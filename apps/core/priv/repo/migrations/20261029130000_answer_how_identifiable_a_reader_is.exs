defmodule Core.Repo.Migrations.AnswerHowIdentifiableAReaderIs do
  @moduledoc """
      `op.count_others_sharing_all/3` — how many OTHER readers shelve the same
      rare books, which is the question the de-anonymisation insight exists to
      answer and the one question its own scope cannot.

      ⛔ The surface has reported "could not compute" to every reader on every
      deployed stack since row-level security went on. The query asks
      `bs.user_id <> $2`, so:

        - **scoped**, the owner policy admits only this reader's rows and the
          `<>` then excludes them, returning a confident **zero** — which tells
          every reader they are maximally identifiable, on the one page whose
          subject is how identifiable they are;
        - **unscoped**, the policy refuses with `42501` and the caller's rescue
          reports "could not compute".

      ⚖️ Loud failure was the right first move and is why this is a residue
      item rather than an incident: a wrong number here is far worse than an
      absent one. What was missing is the mechanism that makes the number right.

      ## Why a definer and not a wider policy

      The question is an aggregate over other people's rows, so no per-user
      scope is correct, and the anonymous scope is wrong in the same worse way
      the transparency-page totals were: it would count only *publicly visible*
      shelvings, a plausible smaller number a reader cannot tell from the truth.
      A definer function narrowed to this one question is the smallest mechanism
      that answers it.

      ## What escapes

      **One integer.** No row, no id, no title. The reader learns how many others
      share their rarest books and nothing about who they are — which is what
      keeps this in the same family as the boolean and the id-list already here
      rather than being a general-purpose read across users.

      ## The argument guard

      A definer runs as its owner, so its arguments are the whole attack
      surface. Two refusals, both `42501`:

        - a scoped caller asking about somebody else — the conditional shape
          `op.blocked_pair/2` established, so an unscoped or anonymous caller
          still falls through for the paths that need it;
        - a NULL subject, which would otherwise match no rows and return a
          confident zero — the exact failure this function exists to end,
          reintroduced one argument lower down.
  """

  use Ecto.Migration

  @app_role "stacks_app"
  @signature "op.count_others_sharing_all(uuid, uuid[], integer)"

  def up do
    execute(function_up())
    execute(ownership_and_grants_up())
    execute(assert_callable())
  end

  def down do
    execute(grants_down())
    execute("DROP FUNCTION IF EXISTS #{@signature};")
  end

  defp function_up do
    """
    CREATE OR REPLACE FUNCTION op.count_others_sharing_all(
      subject uuid,
      book_ids uuid[],
      sample_size integer
    ) RETURNS integer
      LANGUAGE plpgsql
      STABLE
      SECURITY DEFINER
      SET search_path = op, pg_temp
    AS $$
    DECLARE
      scope text := current_setting('app.current_user_id', true);
      others integer;
    BEGIN
      -- A NULL subject would exclude nobody, so every one of this reader's own
      -- shelvings would count as somebody else's and the answer would be a
      -- confident number that is wrong in the alarming direction.
      IF subject IS NULL THEN
        RAISE EXCEPTION
          'count_others_sharing_all needs a subject to exclude; a NULL one would count the reader against themselves'
          USING ERRCODE = '42501';
      END IF;

      -- Refuse only when a real user scope is present and the question is about
      -- somebody else. An absent scope, an emptied one, or the anonymous
      -- sentinel fall through, matching op.blocked_pair/2 — the insight is
      -- computed outside a user scope on purpose and must keep working.
      IF scope IS NOT NULL AND scope <> '' AND scope <> 'unset' AND scope <> 'anonymous' THEN
        IF subject <> scope::uuid THEN
          RAISE EXCEPTION
            'count_others_sharing_all asked how identifiable somebody else is'
            USING ERRCODE = '42501',
                  HINT = 'a reader may only ask this about themselves';
        END IF;
      END IF;

      -- An empty fingerprint shares with everybody, which is not a uniqueness
      -- answer at all. Say so rather than returning the whole user table.
      IF book_ids IS NULL OR array_length(book_ids, 1) IS NULL THEN
        RETURN 0;
      END IF;

      SELECT count(*) INTO others FROM (
        SELECT bs.user_id
          FROM op.bookshelf_placements p
          JOIN op.bookshelves bs ON bs.id = p.bookshelf_id
         WHERE p.book_id = ANY(book_ids)
           AND p.removed_at IS NULL
           AND bs.user_id <> subject
         GROUP BY bs.user_id
        HAVING count(DISTINCT p.book_id) = sample_size
      ) t;

      RETURN others;
    END
    $$
    """
  end

  # ⚠️ REVOKE from PUBLIC first: CREATE FUNCTION grants EXECUTE to PUBLIC by
  # default, which would make the named grant below decorative.
  defp ownership_and_grants_up do
    """
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'rls_reader') THEN
        ALTER FUNCTION #{@signature} OWNER TO rls_reader;
      END IF;

      REVOKE ALL ON FUNCTION #{@signature} FROM PUBLIC;

      IF EXISTS (SELECT FROM pg_roles WHERE rolname = '#{@app_role}') THEN
        GRANT EXECUTE ON FUNCTION #{@signature} TO #{@app_role};
      END IF;
    END $$;
    """
  end

  defp grants_down do
    """
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = '#{@app_role}') THEN
        REVOKE EXECUTE ON FUNCTION #{@signature} FROM #{@app_role};
      END IF;
    END $$;
    """
  end

  # ⛔ THE FAR END. Each claim is the inverse of a way this migration could
  # report success while the reader still sees "could not compute": a grant
  # guarded by `IF EXISTS` on its own grantee reports success when its subject
  # is missing, and a definer that was never reassigned runs as the migrating
  # superuser in development and as nobody useful in production.
  defp assert_callable do
    """
    DO $$ BEGIN
      IF to_regprocedure('#{@signature}') IS NULL THEN
        RAISE EXCEPTION 'op.count_others_sharing_all was not created, so the insight would keep reporting "could not compute"';
      END IF;

      IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure('#{@signature}')) THEN
        RAISE EXCEPTION 'op.count_others_sharing_all is not SECURITY DEFINER, so the policy it exists to step around still refuses it';
      END IF;

      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'rls_reader') THEN
        IF (SELECT pg_get_userbyid(proowner) FROM pg_proc
             WHERE oid = to_regprocedure('#{@signature}')) <> 'rls_reader' THEN
          RAISE EXCEPTION 'op.count_others_sharing_all is not owned by rls_reader, so it runs as whoever migrated rather than as the reader role';
        END IF;
      END IF;

      IF EXISTS (SELECT FROM pg_roles WHERE rolname = '#{@app_role}') THEN
        IF NOT has_function_privilege('#{@app_role}', to_regprocedure('#{@signature}'), 'EXECUTE') THEN
          RAISE EXCEPTION 'role #{@app_role} cannot EXECUTE op.count_others_sharing_all, so the insight would keep reporting "could not compute" on every deployed stack';
        END IF;

        -- ⚠️ PUBLIC is not a role name, so has_function_privilege cannot ask
        -- this; in the ACL a PUBLIC grant is the entry whose grantee oid is 0.
        IF EXISTS (
          SELECT 1
            FROM pg_proc pr, aclexplode(pr.proacl) AS a
           WHERE pr.oid = to_regprocedure('#{@signature}')
             AND a.grantee = 0
             AND a.privilege_type = 'EXECUTE'
        ) THEN
          RAISE EXCEPTION 'op.count_others_sharing_all is still executable by PUBLIC, which makes every named grant here decorative';
        END IF;
      END IF;
    END $$;
    """
  end
end
