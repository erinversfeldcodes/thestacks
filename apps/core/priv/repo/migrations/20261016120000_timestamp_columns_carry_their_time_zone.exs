defmodule Core.Repo.Migrations.TimestampColumnsCarryTheirTimeZone do
  @moduledoc """
      Converts every `timestamp without time zone` column the application owns to
      `timestamptz`.

      The project standard is "All tables UUID PKs + TIMESTAMPTZ". It was
      unreachable through codegen — Ecto maps `:utc_datetime_usec` to a bare
      `timestamp` — so every table violated it by construction. Measured before
      this migration: 139 naive timestamp columns across 52 application tables,
      against exactly one `timestamptz`.

      A naive timestamp is a number with no zone attached, so its meaning depends
      on whoever reads it agreeing about which zone it was written in. That
      agreement is not written down anywhere the database can enforce, and it has
      already failed once: eight of these columns defaulted to
      `now() AT TIME ZONE 'utc'` precisely because a plain `now()` would have
      recorded the session's clock instead.

      ## Why this does not rewrite 52 tables

      `ALTER COLUMN ... TYPE timestamptz` is **metadata-only when the session
      TimeZone is UTC** — Postgres treats the conversion as binary-coercible and
      leaves the heap untouched. Under any other TimeZone it both rewrites the
      table AND shifts every value, because the naive value is interpreted in the
      session zone. Measured on a copy of the development database:

          TimeZone = UTC                  relfilenode unchanged, value 12:50:08+00
          TimeZone = Africa/Johannesburg  relfilenode CHANGED,   value 10:50:19+00

      That second line is a silent two-hour shift of every timestamp in the
      system. Nothing in the deploy path pins TimeZone: the deployed database
      reports `GMT` and a local development machine reports
      `Africa/Johannesburg`. So this migration sets it, and then **proves it took
      before converting anything** — correctness first, the absence of a rewrite
      second. A guard that only logged would be worse than no guard, because the
      damage is invisible: the values are all still plausible timestamps.

      ## Why the column list is discovered rather than written out

      Listing 139 columns would make the migration a snapshot of one database.
      The development database and the deployed one already differ by a column,
      and a hand-written list silently skips whichever columns it does not know
      about — which is the failure this migration exists to end. Discovering them
      from the catalog means the migration converts what is actually there, and
      the final assertion below can then be absolute rather than a count of the
      list it started from.

      ## What it deliberately leaves alone

      Tables whose Ecto schema belongs to a dependency rather than to this
      application. A library's column types are part of its own migration
      contract, and `Postgrex` rejects the mismatch outright rather than
      coercing: a schema declaring a naive datetime against a `timestamptz`
      column raises `expected %DateTime{}, got ~N[…]` on every write.

      These owners are **not** separated by schema, and assuming they were cost
      two separate failures on the way to this version:

        * `guardian_db` files its table **inside `op`** (`config.exs` sets
          `schema_name: "guardian_tokens"`), so excluding "the schemas libraries
          own" converted it anyway. Its `schema "virtual: token"` calls a bare
          `timestamps()` — `:naive_datetime`, with no option to change it — and
          Postgrex refuses the mismatch rather than coercing, so every write
          raised `expected %DateTime{}, got ~N[…]`. 678 tests failed at once,
          every one through `auth_conn/2`.
        * `schema_migrations` lives in `public` on a development database and in
          **`op`** on the deployed one. So a qualified `op.schema_migrations`
          exclusion would have been correct in one environment and silently
          wrong in the other — and this is the table that cannot merely be left
          alone, because Ecto's migration lock holds it open on a separate
          connection for the duration. Asking for ACCESS EXCLUSIVE on it from
          inside the migration blocks on Ecto itself. Observed on the first
          deployed run, with `pg_blocking_pids` naming the lock connection.

      So the exclusion is by BARE TABLE NAME in any schema, and the test that
      accompanies this migration asserts both that these tables stay naive and
      that no dependency other than `guardian_db` and `oban` defines an Ecto
      schema at all — so the list cannot quietly fall out of date.
  """
  use Ecto.Migration

  @breaking_ok "Converts timestamp to timestamptz on every application-owned column. " <>
                 "No value changes and no table rewrite: the conversion is metadata-only " <>
                 "under the UTC session this migration sets and verifies. Readers widen " <>
                 "rather than break — a timestamptz read into Ecto's :utc_datetime_usec " <>
                 "is the pairing op.users.password_reset_sent_at has used in production " <>
                 "since 2026-03. The eight columns whose DEFAULT produced a naive UTC " <>
                 "value have it replaced with now(), which is the same instant."

  # The schemas this application owns. Named positively so that adding a schema
  # is a decision someone makes here, rather than something that silently
  # inherits whatever exclusion list happened to be written.
  @owned_schemas ~w(op audit cache)

  # Tables a dependency owns, excluded by BARE NAME in any schema.
  #
  # Not qualified names, and that is the second lesson this migration learned
  # the hard way. `schema_migrations` lives in `public` on a development
  # database and in `op` on the deployed one — same repository, same config,
  # different schema — so an `op.schema_migrations` exclusion would have been
  # right in exactly one environment and silently wrong in the other. Oban
  # likewise supports a `prefix`, so its tables are not guaranteed to stay in
  # `public` either.
  #
  # ⚠️ `schema_migrations` is the one that cannot merely be left alone: Ecto's
  # own migration lock holds `SELECT version FROM schema_migrations FOR UPDATE`
  # open on a SEPARATE connection for the whole migration, so asking for
  # ACCESS EXCLUSIVE on that table from inside the migration is a guaranteed
  # self-block. It was observed on the first deployed run — `pg_blocking_pids`
  # named Ecto's own lock connection — and the `lock_timeout` above is what
  # turned an indefinite hang into a clean abort with every column intact.
  @library_owned_tables ~w(schema_migrations guardian_tokens oban_jobs oban_peers)

  # dbt's output schemas. Everything in them is derived and rebuilt from the
  # models on every run, which is what makes dropping them safe here.
  @warehouse_schemas ~w(staging intermediate marts)

  # The columns that were ALREADY timestamptz before this migration — exactly
  # one, hand-written in 2026-03 and the only place the stated standard was ever
  # actually met. `up` does not touch it, so `down` must not either: a reverse
  # pass over "every timestamptz column" would convert a column this migration
  # never converted, and the absolute assertion would then certify the damage as
  # success. The exclusion is only sound because the list is verified to be
  # complete by the test that accompanies this migration.
  @already_timestamptz ["op.users.password_reset_sent_at"]

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    # Unbounded: this is 139 catalog updates in one transaction. They are
    # individually instant, but a statement timeout firing partway through would
    # abort a migration that is otherwise harmless, and the transaction already
    # bounds the blast radius.
    execute("SET LOCAL statement_timeout = 0")

    execute("SET LOCAL TimeZone = 'UTC'")
    execute(assert_utc_session())

    execute(drop_warehouse_relations())
    execute(convert_columns("timestamp without time zone", "timestamptz", []))
    execute(assert_no_columns_of_type("timestamp without time zone", []))
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = 0")

    # The same guard, for the same reason and in the same direction: going back
    # to a naive timestamp under a non-UTC session shifts every value too.
    execute("SET LOCAL TimeZone = 'UTC'")
    execute(assert_utc_session())

    execute(drop_warehouse_relations())
    execute(convert_columns("timestamp with time zone", "timestamp", @already_timestamptz))
    execute(assert_no_columns_of_type("timestamp with time zone", @already_timestamptz))
  end

  # Aborts unless the session really is on UTC. `SET LOCAL` can be a silent
  # no-op — outside a transaction it only warns — and the one thing this
  # migration must never do is convert under the wrong zone.
  defp assert_utc_session do
    """
    DO $$
    BEGIN
      IF current_setting('TimeZone') <> 'UTC' THEN
        RAISE EXCEPTION
          'session TimeZone is %, not UTC: converting between timestamp and timestamptz here would shift every value and rewrite every table',
          current_setting('TimeZone');
      END IF;
    END $$;
    """
  end

  # Views over a column block `ALTER COLUMN ... TYPE` outright, and 45 of dbt's
  # relations select these columns. They are dropped rather than preserved
  # because they are derived: `dbt run` rebuilds every one of them from the
  # models in the repository, and dropping them is what the orphan sweep does
  # routinely. Between this migration and the next refresh the community-read
  # mart is absent, which the application already handles by falling back to
  # zero — worth stating because that fallback is silent.
  defp drop_warehouse_relations do
    """
    DO $$
    DECLARE
      rel record;
      dropped int := 0;
    BEGIN
      FOR rel IN
        SELECT n.nspname AS schema, c.relname AS name, c.relkind AS kind
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname IN (#{quoted_list(@warehouse_schemas)})
           AND c.relkind IN ('v', 'm', 'r')
      LOOP
        -- Dispatched on relkind because Postgres rejects DROP TABLE on a view
        -- even with IF EXISTS, which once aborted a sweep at 6 of 15 with a
        -- success exit code.
        CASE rel.kind
          WHEN 'v' THEN
            EXECUTE format('DROP VIEW IF EXISTS %I.%I CASCADE', rel.schema, rel.name);
          WHEN 'm' THEN
            EXECUTE format('DROP MATERIALIZED VIEW IF EXISTS %I.%I CASCADE', rel.schema, rel.name);
          ELSE
            EXECUTE format('DROP TABLE IF EXISTS %I.%I CASCADE', rel.schema, rel.name);
        END CASE;
        dropped := dropped + 1;
      END LOOP;

      RAISE NOTICE 'dropped % warehouse relation(s); dbt rebuilds them on its next run', dropped;
    END $$;
    """
  end

  # The eight columns defaulting to `now() AT TIME ZONE 'utc'` are the reason
  # the default is dropped and re-set rather than left alone. That expression
  # yields a NAIVE value holding UTC; against a timestamptz column it would be
  # cast using the session zone at INSERT time, so every defaulted row would be
  # shifted by the connection's offset. Converting the type without touching the
  # default would therefore reintroduce, in a subtler form, exactly the bug the
  # default was written to fix. `now()` is the same instant with its zone
  # attached.
  defp convert_columns(from_type, to_type, exclusions) do
    """
    DO $$
    DECLARE
      col record;
      converted int := 0;
      redefaulted int := 0;
    BEGIN
      FOR col IN
        SELECT c.table_schema AS schema,
               c.table_name   AS name,
               c.column_name  AS column,
               c.column_default IS NOT NULL AS has_default
          FROM information_schema.columns c
          JOIN information_schema.tables t
            ON t.table_schema = c.table_schema
           AND t.table_name = c.table_name
         WHERE t.table_type = 'BASE TABLE'
           AND c.data_type = '#{from_type}'
           AND c.table_schema IN (#{quoted_list(@owned_schemas)})
           #{library_table_clause()}
           #{exclusion_clause(exclusions)}
         ORDER BY c.table_schema, c.table_name, c.column_name
      LOOP
        IF col.has_default THEN
          EXECUTE format('ALTER TABLE %I.%I ALTER COLUMN %I DROP DEFAULT',
                         col.schema, col.name, col.column);
        END IF;

        EXECUTE format('ALTER TABLE %I.%I ALTER COLUMN %I TYPE #{to_type}',
                       col.schema, col.name, col.column);
        converted := converted + 1;

        IF col.has_default THEN
          EXECUTE format('ALTER TABLE %I.%I ALTER COLUMN %I SET DEFAULT #{default_for(to_type)}',
                         col.schema, col.name, col.column);
          redefaulted := redefaulted + 1;
        END IF;
      END LOOP;

      IF converted = 0 THEN
        RAISE NOTICE 'no #{from_type} columns found — nothing to convert';
      ELSE
        RAISE NOTICE 'converted % column(s) to #{to_type}, % of them re-defaulted',
                     converted, redefaulted;
      END IF;
    END $$;
    """
  end

  # An absolute assertion, which is only honest because the conversion above
  # discovered its own worklist from this same catalog. Had the migration worked
  # from a written-out list, "none remain" would have been a claim about the
  # list rather than about the database.
  defp assert_no_columns_of_type(type, exclusions) do
    """
    DO $$
    DECLARE
      remaining int;
      offenders text;
    BEGIN
      SELECT count(*),
             coalesce(string_agg(c.table_schema || '.' || c.table_name || '.' || c.column_name, ', '), '')
        INTO remaining, offenders
        FROM information_schema.columns c
        JOIN information_schema.tables t
          ON t.table_schema = c.table_schema
         AND t.table_name = c.table_name
       WHERE t.table_type = 'BASE TABLE'
         AND c.data_type = '#{type}'
         AND c.table_schema IN (#{quoted_list(@owned_schemas)})
         #{library_table_clause()}
         #{exclusion_clause(exclusions)};

      IF remaining > 0 THEN
        RAISE EXCEPTION '% column(s) are still %: %', remaining, '#{type}', offenders;
      END IF;
    END $$;
    """
  end

  # `now()` is timestamptz; `now() AT TIME ZONE 'utc'` strips the zone back off
  # for the reverse direction, which is the expression these columns carried
  # before this migration.
  defp default_for("timestamptz"), do: "now()"
  defp default_for("timestamp"), do: "(now() AT TIME ZONE ''utc'')"

  defp quoted_list(values), do: Enum.map_join(values, ", ", &"'#{&1}'")

  defp library_table_clause do
    "AND c.table_name NOT IN (#{quoted_list(@library_owned_tables)})"
  end

  defp exclusion_clause([]), do: ""

  defp exclusion_clause(exclusions) do
    "AND c.table_schema || '.' || c.table_name || '.' || c.column_name " <>
      "NOT IN (#{quoted_list(exclusions)})"
  end
end
