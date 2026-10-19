defmodule Core.Repo.Migrations.GrantTheAppRoleItsOwnJobQueue do
  @moduledoc """
      Gives `stacks_app` the privileges Oban needs, which live in `public`.

      ## The gap

      `config/runtime.exs` points BOTH runtime pools at `APP_DATABASE_URL`:

          config :core, Core.Repo,     url: app_database_url
          config :core, Core.ObanRepo, url: app_database_url

      The predecessor roles migration grants on `op`, `audit`, and the warehouse
      schemas. It never mentions `public` — and Oban's tables live there.

      ⛔ Measured on production and on a preview carrying the full campaign
      migration set, `stacks_app` held **no privilege at all** on any of these:

          public.oban_jobs         SELECT/INSERT/UPDATE/DELETE  all false
          public.oban_jobs_id_seq  USAGE                        false
          public.oban_peers        SELECT/INSERT/UPDATE/DELETE  all false

      So setting `APP_DATABASE_URL` would have stopped EVERY background job: no
      job insertable, claimable, prunable or rescuable. That means the retention
      sweep, notifications, the vision pipeline and event delivery, all at once.

      ⚠️ The fallback is what hid it. Unset, both pools use the owner URL, so
      the least-privilege path has never executed on any stack — the first run
      would have been production.

      ## Why the sequence matters as much as the table

      `oban_jobs.id` is a bigint backed by `public.oban_jobs_id_seq`, and INSERT
      needs USAGE on it. Granting DML on the table alone produces a role that can
      read and delete jobs but not enqueue one — a half-working queue, which is
      harder to diagnose than one that fails outright.

      ## Why a new migration rather than editing the predecessor

      The predecessor has NOT run on production, so editing it would have worked
      there. It HAS run on local databases and on the current preview, which
      would therefore never pick up an edit. A separate migration applies
      everywhere exactly once, regardless of what each database has already seen.

      ## The far-end assertion

      The predecessor's own moduledoc records the lesson this migration is built
      on: a grant guarded by `IF EXISTS` on its grantee reports success when the
      grantee is missing. That is how the March roles migration "succeeded" while
      granting nothing for months. So the grants here are guarded — a developer
      database legitimately has no `stacks_app` — but when the role IS present,
      this asserts the privileges actually landed and raises if they did not.
  """
  use Ecto.Migration

  @app_role "stacks_app"

  # ⚠️ Oban's tables are named ONE BY ONE, deliberately, for two reasons.
  #
  # Not `ALL TABLES IN SCHEMA public`, because `public` also holds
  # `schema_migrations`, which the runtime role must never be able to write — a
  # sweep would hand it the ability to rewrite migration history.
  #
  # And not built by interpolating a list either, which is how this was first
  # written: the only offline guard on this grant is a source-level assertion in
  # `database_role_split_test.exs`, because no local or CI run ever connects as
  # `stacks_app`. A grant assembled as `ON public.#{table}` is invisible to that
  # assertion — it failed against exactly that, which is the test doing its job.
  # Literal SQL here keeps the guard able to see what was granted.

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    execute(grants_up(), grants_down())
    execute(assert_granted())
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute(grants_down())
  end

  defp grants_up do
    """
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = '#{@app_role}') THEN
        GRANT USAGE ON SCHEMA public TO #{@app_role};

        IF to_regclass('public.oban_jobs') IS NOT NULL THEN
          GRANT SELECT, INSERT, UPDATE, DELETE ON public.oban_jobs TO #{@app_role};
        END IF;

        IF to_regclass('public.oban_peers') IS NOT NULL THEN
          GRANT SELECT, INSERT, UPDATE, DELETE ON public.oban_peers TO #{@app_role};
        END IF;

        -- INSERT is impossible without this, so a table-only grant yields a
        -- role that can read and delete jobs but never enqueue one.
        IF to_regclass('public.oban_jobs_id_seq') IS NOT NULL THEN
          GRANT USAGE, SELECT ON SEQUENCE public.oban_jobs_id_seq TO #{@app_role};
        END IF;

        -- Future Oban tables, so an Oban upgrade that adds one does not
        -- silently leave the runtime role unable to use it.
        ALTER DEFAULT PRIVILEGES IN SCHEMA public
          GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO #{@app_role};
        ALTER DEFAULT PRIVILEGES IN SCHEMA public
          GRANT USAGE, SELECT ON SEQUENCES TO #{@app_role};

        -- ⚠️ Migration history stays out of reach. The default privileges above
        -- cover tables created LATER; this revoke covers the one that already
        -- exists and must never be writable by the runtime role.
        IF to_regclass('public.schema_migrations') IS NOT NULL THEN
          REVOKE ALL ON public.schema_migrations FROM #{@app_role};
        END IF;
      END IF;
    END $$;
    """
  end

  defp grants_down do
    """
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = '#{@app_role}') THEN
        ALTER DEFAULT PRIVILEGES IN SCHEMA public
          REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM #{@app_role};
        ALTER DEFAULT PRIVILEGES IN SCHEMA public
          REVOKE USAGE, SELECT ON SEQUENCES FROM #{@app_role};

        IF to_regclass('public.oban_jobs_id_seq') IS NOT NULL THEN
          REVOKE ALL ON SEQUENCE public.oban_jobs_id_seq FROM #{@app_role};
        END IF;

        IF to_regclass('public.oban_jobs') IS NOT NULL THEN
          REVOKE ALL ON public.oban_jobs FROM #{@app_role};
        END IF;

        IF to_regclass('public.oban_peers') IS NOT NULL THEN
          REVOKE ALL ON public.oban_peers FROM #{@app_role};
        END IF;
      END IF;
    END $$;
    """
  end

  # ⛔ The far end. Without this the migration reports success on a database
  # where the role exists and the grants did not land — which is exactly how the
  # March roles migration passed for months while granting nothing.
  defp assert_granted do
    """
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = '#{@app_role}')
         AND to_regclass('public.oban_jobs') IS NOT NULL THEN

        IF NOT has_table_privilege('#{@app_role}', 'public.oban_jobs', 'INSERT') THEN
          RAISE EXCEPTION
            'role #{@app_role} still cannot INSERT into public.oban_jobs after this migration — it granted nothing and would have reported success';
        END IF;

        IF to_regclass('public.oban_jobs_id_seq') IS NOT NULL
           AND NOT has_sequence_privilege('#{@app_role}', 'public.oban_jobs_id_seq', 'USAGE') THEN
          RAISE EXCEPTION
            'role #{@app_role} cannot use public.oban_jobs_id_seq, so it cannot enqueue a job even though the table grant succeeded';
        END IF;

        IF has_table_privilege('#{@app_role}', 'public.schema_migrations', 'UPDATE') THEN
          RAISE EXCEPTION
            'role #{@app_role} can write public.schema_migrations — the runtime role must never be able to rewrite migration history';
        END IF;
      END IF;
    END $$;
    """
  end
end
