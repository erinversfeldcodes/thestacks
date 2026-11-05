defmodule Core.Repo.Migrations.AssertTheDefinerCanReadWhatItWasWrittenToRead do
  @moduledoc """
      ⛔ FIVE ASSERTIONS GUARDED `op.count_others_sharing_all/3` AND NONE OF THEM
      CHECKED IT COULD DO ITS JOB.

      Its own migration asserts the function exists, is `SECURITY DEFINER`, is
      owned by `rls_reader`, is EXECUTE-able by `stacks_app`, and is NOT
      executable by PUBLIC. Every one of those is a fact about privileges ON the
      function. None is a fact about the function's ability to READ.

      ⚖️ That gap is not theoretical. The function reads `op.bookshelves` and
      `op.bookshelf_placements` as `rls_reader`, which can see them only because
      an earlier migration granted SELECT and created a
      `FOR SELECT TO rls_reader USING (true)` policy on each. Nothing in the
      function's own migration names that dependency. Narrow that earlier list,
      or drop a policy, and this function returns **0 for every reader** — which
      is precisely the defect it was written to end (a confident zero telling
      every reader they are maximally identifiable), while its migration reports
      success.

      ⛔ Measured before writing this: dropping `bookshelves_definer_read` reds
      four cases in `insights_test.exs`, all with `left: nil`. So the SUITE
      catches it. The suite does not run on deploy; migrations do.

      ⚠️ This asserts nothing about data, so it is safe on an empty database. It
      derives the owner FROM the function rather than taking `rls_reader` on
      trust, which is what keeps it from being the shape this family of
      assertions is warned about — a check guarded by `IF EXISTS` on its own
      subject, reporting success when the subject is missing.
  """

  use Ecto.Migration

  @signature "op.count_others_sharing_all(uuid, uuid[], integer)"
  @tables ~w(bookshelves bookshelf_placements)

  def up, do: execute(assert_readable())

  # Nothing to undo: this migration creates no object. The `down` exists so the
  # migration is reversible rather than blocking a rollback of its neighbours.
  def down, do: :ok

  defp assert_readable do
    """
    DO $$
    DECLARE
      owner_role text;
      t text;
    BEGIN
      SELECT pg_get_userbyid(proowner) INTO owner_role
        FROM pg_proc WHERE oid = to_regprocedure('#{@signature}');

      IF owner_role IS NULL THEN
        RAISE EXCEPTION
          'op.count_others_sharing_all is missing, so the de-anonymisation insight reports "could not compute" to every reader';
      END IF;

      FOREACH t IN ARRAY ARRAY[#{Enum.map_join(@tables, ", ", &"'#{&1}'")}] LOOP
        IF NOT has_table_privilege(owner_role, 'op.' || t, 'SELECT') THEN
          RAISE EXCEPTION
            'the definer runs as % which cannot SELECT op.%, so it would count zero other readers and tell everyone they are maximally identifiable',
            owner_role, t;
        END IF;

        IF NOT EXISTS (
          SELECT 1 FROM pg_policies
           WHERE schemaname = 'op' AND tablename = t AND owner_role = ANY(roles)
        ) THEN
          RAISE EXCEPTION
            'no row-level-security policy on op.% admits %, so the definer sees zero rows there however broad its GRANT',
            t, owner_role;
        END IF;
      END LOOP;
    END $$;
    """
  end
end
