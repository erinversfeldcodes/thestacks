defmodule Core.TimestampColumnTypesTest do
  @moduledoc """
      The standing guard behind "All tables UUID PKs + TIMESTAMPTZ".

      That line was in the project conventions for months while the database held
      139 `timestamp without time zone` columns across 52 tables and exactly one
      `timestamptz`. Nothing noticed, because nothing asked: the standard was
      written down in prose and checked by no one, and the generator that creates
      most of these tables could not have produced a conforming column even
      deliberately — Ecto maps `:utc_datetime_usec` to a bare `timestamp`.

      So this suite asks the database directly, on every run. It is the half of
      the fix that keeps working after the migration has run: a migration
      converts what exists once, while this fails the build the next time a naive
      timestamp column is added.
  """
  use Core.DataCase, async: true

  alias Core.Repo

  # Mirrors the migration's `@owned_schemas`. If a new application schema is
  # added, both lists have to learn about it — the duplication is deliberate,
  # because a shared constant would let a schema be silently dropped from the
  # guard by editing the migration.
  @owned_schemas ~w(op audit cache)

  # `public` holds Oban's and Ecto's own tables (`oban_jobs`, `oban_peers`,
  # `schema_migrations`).
  @library_owned_schemas ~w(public)

  # ⚠️ Library ownership does NOT follow schema boundaries, and these are BARE
  # NAMES rather than qualified ones for a measured reason.
  #
  # `guardian_db` files its table inside `op` (`config.exs` sets
  # `schema_name: "guardian_tokens"`), so a sweep that excluded "the schemas
  # libraries own" converted it anyway — 678 test failures in one run, every one
  # through `auth_conn/2`, because Postgrex refuses a naive/aware mismatch
  # rather than coercing it.
  #
  # `schema_migrations` is worse: it lives in `public` on a development database
  # and in `op` on the deployed one. A qualified exclusion would have been right
  # in one environment and silently wrong in the other, and this is the table
  # Ecto's own migration lock holds open for the duration of a migration — so
  # converting it blocks on Ecto itself.
  @library_owned_tables ~w(schema_migrations guardian_tokens oban_jobs oban_peers)

  defp columns_of_type(type, schemas) do
    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT c.table_schema || '.' || c.table_name || '.' || c.column_name
          FROM information_schema.columns c
          JOIN information_schema.tables t
            ON t.table_schema = c.table_schema
           AND t.table_name = c.table_name
         WHERE t.table_type = 'BASE TABLE'
           AND c.data_type = $1
           AND c.table_schema = ANY($2)
         ORDER BY 1
        """,
        [type, schemas]
      )

    List.flatten(rows)
  end

  describe "application timestamp columns" do
    test "no application-owned column is a naive timestamp" do
      naive =
        "timestamp without time zone"
        |> columns_of_type(@owned_schemas)
        |> Enum.reject(fn column ->
          # "schema.table.column" — the middle segment is the table name, and
          # the exclusions are bare names so they hold in whichever schema the
          # dependency happens to have filed its table under.
          [_schema, table, _col] = String.split(column, ".", parts: 3)
          table in @library_owned_tables
        end)

      assert naive == [],
             "#{length(naive)} column(s) carry a timestamp with no time zone, so their " <>
               "meaning depends on every reader agreeing which zone wrote them:\n  " <>
               Enum.join(naive, "\n  ")
    end

    # Anti-vacuity. The assertion above is satisfied by an empty database, a
    # wrong schema name, or a typo in the type string — all of which would read
    # as a pass. This pins that the query is actually looking at the columns in
    # question.
    test "the sweep is looking at a populated schema" do
      timestamptz = columns_of_type("timestamp with time zone", @owned_schemas)

      assert length(timestamptz) > 100,
             "expected the application schemas to hold well over a hundred timestamptz " <>
               "columns (139 were converted); found #{length(timestamptz)}, which means " <>
               "this sweep is not reading the schemas it names"
    end

    test "a known column is covered, by name" do
      timestamptz = columns_of_type("timestamp with time zone", @owned_schemas)

      # Three specific columns rather than a count: one from each owned schema,
      # so a schema silently falling out of the sweep is caught. `cache` in
      # particular holds only two tables and would be easy to lose in a count.
      for column <- [
            "op.users.created_at",
            "audit.audit_log.occurred_at",
            "cache.isbn_resolver_cache.expires_at"
          ] do
        assert column in timestamptz,
               "#{column} is not timestamptz — either it regressed, or the sweep stopped " <>
                 "covering its schema"
      end
    end
  end

  describe "defaults on timestamptz columns" do
    # The subtle half of the conversion. `now() AT TIME ZONE 'utc'` yields a
    # NAIVE value holding UTC; assigned to a timestamptz column it is re-read in
    # the session zone, so every defaulted row lands off by the connection's
    # offset. Measured on a development machine: 7200 seconds. A type conversion
    # that left these defaults in place would have reintroduced the exact bug the
    # defaults were written to fix, in a form no type check would catch.
    test "no timestamptz column defaults to a zone-stripped expression" do
      {:ok, %{rows: rows}} =
        Repo.query(
          """
          SELECT c.table_schema || '.' || c.table_name || '.' || c.column_name,
                 c.column_default
            FROM information_schema.columns c
            JOIN information_schema.tables t
              ON t.table_schema = c.table_schema
             AND t.table_name = c.table_name
           WHERE t.table_type = 'BASE TABLE'
             AND c.data_type = 'timestamp with time zone'
             AND c.table_schema = ANY($1)
             AND c.column_default IS NOT NULL
             AND c.column_default ILIKE '%at time zone%'
           ORDER BY 1
          """,
          [@owned_schemas]
        )

      assert rows == [],
             "these timestamptz columns default to an expression that strips the zone " <>
               "back off, so a row inserted from a non-UTC connection is stored at the " <>
               "wrong instant:\n  " <>
               Enum.map_join(rows, "\n  ", fn [col, default] -> "#{col} => #{default}" end)
    end

    test "the eight defaulted columns default to now()" do
      {:ok, %{rows: rows}} =
        Repo.query(
          """
          SELECT c.column_default, count(*)
            FROM information_schema.columns c
            JOIN information_schema.tables t
              ON t.table_schema = c.table_schema
             AND t.table_name = c.table_name
           WHERE t.table_type = 'BASE TABLE'
             AND c.data_type = 'timestamp with time zone'
             AND c.table_schema = ANY($1)
             AND c.column_default IS NOT NULL
           GROUP BY 1
          """,
          [@owned_schemas]
        )

      assert rows == [["now()", 8]],
             "expected exactly eight defaulted timestamptz columns, all on now(); got " <>
               inspect(rows)
    end
  end

  describe "library-owned tables" do
    # Asserted as a positive expectation rather than left unmentioned. These
    # columns are naive on purpose, and a future sweep that "finished the job" by
    # converting them would break Oban's own schemas — which declare
    # `:naive_datetime_usec` — and collide with the next library-supplied
    # migration. Stating it here means the exclusion is a decision on the record
    # rather than an oversight someone later tidies up.
    test "Oban's and Ecto's own timestamp columns are left naive" do
      naive = columns_of_type("timestamp without time zone", @library_owned_schemas)

      for column <- [
            "public.oban_jobs.inserted_at",
            "public.oban_jobs.scheduled_at",
            "public.oban_peers.expires_at",
            "public.schema_migrations.inserted_at"
          ] do
        assert column in naive,
               "#{column} is no longer a naive timestamp. Oban and Ecto own these tables " <>
                 "and their schemas declare naive datetimes; converting them is not ours " <>
                 "to do"
      end
    end

    # The one that matters, because it is the one that already went wrong. This
    # column is inside `op`, so every schema-shaped rule in this file and in the
    # migration says it should be timestamptz, and it must not be.
    test "guardian_db's table stays naive even though it lives in op" do
      naive = columns_of_type("timestamp without time zone", @owned_schemas)

      for column <- ["op.guardian_tokens.inserted_at", "op.guardian_tokens.updated_at"] do
        assert column in naive,
               "#{column} was converted to timestamptz. guardian_db's schema declares a " <>
                 "naive datetime and Postgrex raises on the mismatch rather than coercing, " <>
                 "so this breaks every authenticated request"
      end
    end

    # ⚠️ Asserted WHEREVER the table lives, because where it lives differs by
    # environment: `public` here, `op` on the deployed database. The assertion
    # is therefore on the name, and it is satisfied by the table being naive in
    # whichever schema this database happens to keep it.
    #
    # Converting it is not merely unnecessary. Ecto's migration lock holds
    # `SELECT version FROM schema_migrations FOR UPDATE` open on a separate
    # connection for the whole migration, so a migration asking for ACCESS
    # EXCLUSIVE on that table blocks on Ecto itself — observed on the first
    # deployed run, aborted by the migration's own lock_timeout with every
    # column intact.
    test "the Ecto migrations table stays naive, in whatever schema it lives in" do
      {:ok, %{rows: rows}} =
        Repo.query("""
        SELECT c.table_schema, c.data_type
          FROM information_schema.columns c
          JOIN information_schema.tables t
            ON t.table_schema = c.table_schema
           AND t.table_name = c.table_name
         WHERE t.table_type = 'BASE TABLE'
           AND c.table_name = 'schema_migrations'
           AND c.column_name = 'inserted_at'
        """)

      assert rows != [],
             "no schema_migrations.inserted_at column found at all — this sweep is not " <>
               "looking at a migrated database"

      for [schema, type] <- rows do
        assert type == "timestamp without time zone",
               "#{schema}.schema_migrations.inserted_at is #{type}. Ecto owns this table " <>
                 "and holds it locked for the duration of a migration, so converting it " <>
                 "makes any future migration that touches it block on Ecto itself"
      end
    end

    # Anti-vacuity for the exclusion itself: the list is only safe while
    # `guardian_db` and `oban` remain the only dependencies defining Ecto
    # schemas. A new dependency that files a table in `op` would be converted by
    # the migration and discovered the way this one was — in production.
    test "no dependency other than guardian_db and oban defines an Ecto schema" do
      deps_root = Path.expand("../../../../deps", __DIR__)

      schema_owners =
        deps_root
        |> Path.join("*/lib/**/*.ex")
        |> Path.wildcard()
        |> Enum.filter(&(File.read!(&1) =~ ~r/^\s*use Ecto\.Schema/m))
        |> Enum.map(fn path ->
          path |> Path.relative_to(deps_root) |> Path.split() |> List.first()
        end)
        |> Enum.uniq()
        |> Enum.sort()

      # `ecto`, `ecto_sql` and `cloak_ecto` define schemas in their own test or
      # example modules and own no tables here.
      unexpected = schema_owners -- ~w(cloak_ecto ecto ecto_sql guardian_db oban)

      assert unexpected == [],
             "#{inspect(unexpected)} define Ecto schemas. If any of them creates a table " <>
               "inside #{inspect(@owned_schemas)}, the timestamptz migration will convert " <>
               "it and the library will raise on the type it did not expect. Check where " <>
               "their tables live and add them to the exclusion list if needed."
    end
  end
end
