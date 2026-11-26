defmodule Stacks.Workers.LibraryImportRowRetentionJobTest do
  @moduledoc """
      The nightly sweep that deletes raw import rows once their 30 days are up.

      A raw row holds the reader's own Goodreads review and their private notes,
      kept only to power the one-time per-row report. This job is the entire
      mechanism by which that text stops existing, and it had no test — so
      "the free text is deleted on a schedule" rested on reading the query.

      The last test here is the one worth explaining. The sweep is
      `where created_at < cutoff`, and a NULL never satisfies a `<`, so a row
      with no `created_at` is swept NEVER: the reader's text survives
      permanently and the job's log line reports what it deleted, not what it
      could not see. A validated CHECK plus a `now()` default is what stops
      that, and both are asserted against the live catalogue rather than
      assumed, because `Imports.insert_import/3` writes through `insert_all` —
      which bypasses the changeset and the Ecto schema default alike, leaving
      the table itself as the only thing that can enforce it.

      A CHECK rather than `SET NOT NULL` because the latter scans the table
      under ACCESS EXCLUSIVE; the constraint is enforced identically on every
      write, so the guard asserts the constraint and that it is VALIDATED. An
      unvalidated CHECK binds new writes but says nothing about the rows
      already there, which is exactly the population this fix exists for.
  """
  use Core.DataCase, async: false

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Imports
  alias Stacks.Imports.LibraryImport
  alias Stacks.Imports.LibraryImportRow
  alias Stacks.Workers.LibraryImportRowRetentionJob

  defp days_ago(days), do: DateTime.add(DateTime.utc_now(), -days, :day)

  defp run, do: LibraryImportRowRetentionJob.perform(%Oban.Job{args: %{}})

  describe "perform/1" do
    test "deletes a row whose retention has expired" do
      row =
        insert(:library_import_row,
          raw_review: "I have thoughts about this and they are mine",
          created_at: days_ago(Imports.row_retention_days() + 1)
        )

      assert :ok = run()

      refute Repo.get(LibraryImportRow, row.id)
    end

    test "keeps a row still inside its retention window" do
      row = insert(:library_import_row, created_at: days_ago(Imports.row_retention_days() - 1))

      assert :ok = run()

      assert Repo.get(LibraryImportRow, row.id)
    end

    test "the import survives its rows — the summary is durable, the raw material is not" do
      import_record = insert(:library_import, row_count: 1)

      insert(:library_import_row,
        import: import_record,
        created_at: days_ago(Imports.row_retention_days() + 1)
      )

      assert :ok = run()

      assert Repo.get(LibraryImport, import_record.id)

      assert Repo.aggregate(
               from(r in LibraryImportRow, where: r.import_id == ^import_record.id),
               :count
             ) == 0
    end
  end

  describe "no row can hide from the sweep" do
    test "a validated constraint requires created_at, and a default fills it" do
      {:ok, %{rows: constraints}} =
        Repo.query("""
        SELECT convalidated
        FROM pg_constraint
        WHERE conrelid = 'op.library_import_rows'::regclass
          AND conname = 'library_import_rows_created_at_present'
        """)

      assert [[validated]] = constraints,
             "op.library_import_rows has no constraint requiring created_at — a row without " <>
               "one never satisfies the retention sweep's `< cutoff`, so the reader's review " <>
               "and notes would be kept permanently with nothing reporting it"

      assert validated,
             "the constraint exists but is NOT VALID, so it binds new writes and says nothing " <>
               "about the rows already there — which is the population this exists for"

      {:ok, %{rows: defaults}} =
        Repo.query("""
        SELECT pg_get_expr(d.adbin, d.adrelid)
        FROM pg_attribute a
        LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
        WHERE a.attrelid = 'op.library_import_rows'::regclass
          AND a.attname = 'created_at'
        """)

      assert [[default]] = defaults

      assert to_string(default) =~ "now()",
             "the column lost its default — a writer that omits created_at would now fail the " <>
               "insert rather than start the retention clock, and insert_all is the write path"
    end

    test "the constraint actually refuses a row with no created_at" do
      # The catalogue assertions above describe the schema; this one exercises
      # it, because a constraint that exists and a constraint that fires are
      # different claims.
      import_record = insert(:library_import)

      # The constraint NAME is asserted, not just that something raised. Without
      # it a typo in this INSERT — a renamed column, a missing NOT NULL field —
      # also raises `Postgrex.Error`, and the test would pass while proving
      # nothing about the constraint it is named after.
      assert_raise Postgrex.Error, ~r/library_import_rows_created_at_present/, fn ->
        Repo.query!(
          """
          INSERT INTO op.library_import_rows (id, import_id, row_number, raw_rating,
                                              raw_read_count, raw_owned_copies, created_at)
          VALUES (gen_random_uuid(), $1, 999, 0, 0, 0, NULL)
          """,
          [Ecto.UUID.dump!(import_record.id)]
        )
      end
    end

    test "the column the sweep filters on is indexed" do
      {:ok, %{rows: rows}} =
        Repo.query("""
        SELECT indexdef
        FROM pg_indexes
        WHERE schemaname = 'op'
          AND tablename = 'library_import_rows'
          AND indexdef LIKE '%(created_at)%'
        """)

      assert rows != [],
             "no index leads with created_at, so the one query whose job is to delete the " <>
               "reader's free text on time scans the whole table that holds it"
    end
  end
end
