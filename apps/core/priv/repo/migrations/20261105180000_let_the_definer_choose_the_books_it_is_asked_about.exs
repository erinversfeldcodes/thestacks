defmodule Core.Repo.Migrations.LetTheDefinerChooseTheBooksItIsAskedAbout do
  @moduledoc """
      ⛔ THE CALLER NO LONGER NAMES THE BOOKS, AND THAT WAS A REAL CHANNEL.

      `op.count_others_sharing_all(subject, book_ids, sample_size)` took the
      fingerprint as an argument. The Elixir side derived it from the subject's
      own placements, so the intended question was always "how identifiable is
      this reader's own shelf" — but the SQL could not verify that, and as a
      SECURITY DEFINER it reads every row.

      So with `subject` set to oneself, which the scope check permits, a caller
      could ask "how many users hold ALL of [any set of books]" for a set they
      do not own. The answer is community co-ownership statistics for an
      arbitrary combination, obtained one probe at a time. The scope check
      bounded WHO the question was about and nothing bounded WHAT was asked.

      ⚖️ The fix is to take the question away from the caller rather than to
      validate it. The function now derives the fingerprint itself — the
      subject's own distinct shelved books, rarest first — so the only question
      expressible is the one the insight exists to answer. `fingerprint_size`
      stays an input because it is a bound on the answer's precision, not a
      choice of whose rows to read.

      ⚠️ Found by `scripts/check-deployed-posture.sh`'s
      `definer_takes_a_user_list_as_its_subject`, which refuses a `uuid[]` input
      to a definer unless it is named `exclude*` — an exclusion list narrows what
      a definer returns, a selection list chooses it. The sibling
      `op.group_feed_placements` passes that assertion because its array is
      `exclude_*`. This one did not, and the gate was right.
  """
  use Ecto.Migration

  def up do
    # ⚠️ `SET LOCAL`, inside the migration's transaction, matching the sibling
    # migrations. A `DROP FUNCTION` needs an exclusive lock on the function, so
    # a concurrent call holds it up — bounded here rather than left to block a
    # deploy indefinitely.
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    # The old shape goes, rather than being left callable beside the new one.
    # A definer that still accepts the caller's book list is the channel, and
    # an overload is exactly what `definer_set_has_no_unexpected_function`
    # warns about.
    execute("DROP FUNCTION IF EXISTS op.count_others_sharing_all(uuid, uuid[], integer)")

    execute("""
    CREATE OR REPLACE FUNCTION op.count_others_sharing_all(subject uuid, fingerprint_size integer)
    RETURNS TABLE (sample_size integer, others integer)
    LANGUAGE plpgsql
    STABLE SECURITY DEFINER
    SET search_path TO 'op', 'pg_temp'
    AS $fn$
    DECLARE
      scope text := current_setting('app.current_user_id', true);
      fingerprint uuid[];
    BEGIN
      -- A NULL subject would exclude nobody, so every one of this reader's own
      -- shelvings would count as somebody else's and the answer would be a
      -- confident number wrong in the alarming direction.
      IF subject IS NULL THEN
        RAISE EXCEPTION
          'count_others_sharing_all needs a subject to exclude; a NULL one would count the reader against themselves'
          USING ERRCODE = '42501';
      END IF;

      -- Refuse only when a real user scope is present and the question is
      -- about somebody else. An absent scope, an emptied one, or the anonymous
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

      IF fingerprint_size IS NULL OR fingerprint_size < 1 THEN
        RAISE EXCEPTION
          'count_others_sharing_all needs a positive fingerprint size'
          USING ERRCODE = '22023';
      END IF;

      -- ⛔ DERIVED HERE, NOT PASSED IN. The subject's own distinct shelved
      -- books, rarest in the community first, capped at the requested size.
      -- Ties break on the id so the fingerprint is stable between calls.
      SELECT array_agg(book_id ORDER BY readers ASC, book_id ASC)
        INTO fingerprint
        FROM (
          SELECT mine.book_id,
                 (SELECT count(DISTINCT bs2.user_id)
                    FROM op.bookshelf_placements p2
                    JOIN op.bookshelves bs2 ON bs2.id = p2.bookshelf_id
                   WHERE p2.book_id = mine.book_id
                     AND p2.removed_at IS NULL) AS readers
            FROM (
              SELECT DISTINCT p.book_id
                FROM op.bookshelf_placements p
                JOIN op.bookshelves bs ON bs.id = p.bookshelf_id
               WHERE bs.user_id = subject
                 AND p.removed_at IS NULL
            ) mine
          ORDER BY readers ASC, book_id ASC
          LIMIT fingerprint_size
        ) ranked;

      -- An empty fingerprint shares with everybody, which is not a uniqueness
      -- answer at all. Report a sample of nothing rather than the user table.
      IF fingerprint IS NULL OR array_length(fingerprint, 1) IS NULL THEN
        RETURN QUERY SELECT 0, 0;
        RETURN;
      END IF;

      RETURN QUERY
      SELECT array_length(fingerprint, 1),
             (SELECT count(*)::integer FROM (
                SELECT bs.user_id
                  FROM op.bookshelf_placements p
                  JOIN op.bookshelves bs ON bs.id = p.bookshelf_id
                 WHERE p.book_id = ANY(fingerprint)
                   AND p.removed_at IS NULL
                   AND bs.user_id <> subject
                 GROUP BY bs.user_id
                HAVING count(DISTINCT p.book_id) = array_length(fingerprint, 1)
              ) t);
    END
    $fn$
    """)

    # CREATE FUNCTION grants EXECUTE to PUBLIC by default, so the grant has to
    # be narrowed explicitly or the definer is callable by every role that can
    # connect — which is what `definer_function_executable_by_public` asserts.
    execute("REVOKE ALL ON FUNCTION op.count_others_sharing_all(uuid, integer) FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION op.count_others_sharing_all(uuid, integer) TO stacks_app")
  end

  # ⛔ `down` RESTORES THE THREE-ARGUMENT FORM, and merely dropping the new one
  # was a reversibility bug that `just ci` caught.
  #
  # `20261029130000.down` revokes and drops
  # `op.count_others_sharing_all(uuid, uuid[], integer)` — the shape `up` above
  # removes. A `down` that only dropped the two-argument form therefore left its
  # predecessor revoking a function that no longer existed, and a rollback past
  # this migration died on `42883 undefined_function` naming the old signature.
  #
  # ⚖️ A `down` has to leave the schema as its `up` found it, not merely undo
  # the statement it personally wrote. The old body is restored verbatim from
  # the creating migration, with its ownership and grant, so the predecessor's
  # `down` finds exactly what it expects.
  #
  # ⚠️ This re-opens the channel the `up` closes, which is correct: rolling back
  # means returning to the previous behaviour, hazard included. The safety
  # argument for a rollback is that it is deliberate and brief, not that the old
  # code was sound.
  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")
    execute("DROP FUNCTION IF EXISTS op.count_others_sharing_all(uuid, integer)")

    execute("""
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
    """)

    execute(
      "ALTER FUNCTION op.count_others_sharing_all(uuid, uuid[], integer) OWNER TO rls_reader"
    )

    execute(
      "REVOKE ALL ON FUNCTION op.count_others_sharing_all(uuid, uuid[], integer) FROM PUBLIC"
    )

    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_app') THEN
        GRANT EXECUTE ON FUNCTION op.count_others_sharing_all(uuid, uuid[], integer) TO stacks_app;
      END IF;
    END $$;
    """)
  end
end
