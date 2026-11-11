{#
  Grant the application and read-only roles SELECT on everything this run
  built in the marts schema.

  Called from `on-run-end` in dbt_project.yml, so it runs as the dbt role —
  which owns the relations and can therefore grant on them. The migration that
  creates these schemas deliberately does NOT do this: `ALTER DEFAULT
  PRIVILEGES FOR ROLE stacks_dbt` requires the caller to own or be a member of
  that role, and the migration role is neither. On a fresh database with a
  non-superuser migrator it fails with "permission denied to change default
  privileges" and takes the deploy with it.

  Re-granting on every run is deliberate. dbt drops and recreates views, and a
  recreated relation comes back with a fresh ACL — so a grant applied once is
  correct until the next build and silently wrong afterwards.

  Only `marts` is granted. `staging` and `intermediate` are dbt's working
  surfaces and carry columns the warehouse rules keep away from readers; the
  app has no business selecting from either.
#}
{#
  ⚠️ THIS HOOK GRANTED NOTHING, ANYWHERE, FROM THE DAY IT WAS WRITTEN UNTIL
  2026-10-16, and the reason is worth keeping because it is a shape rather than
  a typo.

  It was guarded by `target.name != 'dev'`, on the reasonable-sounding theory
  that a local database has no roles to grant to. But `dbt/profiles.yml`
  declares exactly ONE output, named `dev` — deliberately, because the
  alternative is a per-environment target name, and the last one of those
  (`--target preview`) was invoked by a script for months without existing at
  all. So `target.name` is the constant string `dev` on every machine, the
  condition was always false, and the hook logged "skipping" and returned.
  Found by reading the log of the first successful deployed run, not by any
  gate: a hook that is correctly wired and does nothing produces no failure.

  The theory was also wrong on its own terms. `setup.sh` creates `stacks_app`,
  `stacks_dbt` and `stacks_readonly` locally, so there WERE roles to grant to;
  and the `IF EXISTS` guards below mean a database missing them is a no-op
  rather than an error. There was nothing to protect against in either
  direction.
#}
{% macro grant_marts_select() %}
  {#
    `{% if execute %}`, not `{% if true %}`. dbt evaluates every macro twice:
    once while parsing, when `run_query` returns None, and once for real. The
    first version of this fix read the returned table unconditionally and failed
    the whole run with `'None' has no attribute 'table'` — during the
    `run-operation` that precedes the build, so it took the orphan sweep with
    it. `drop_orphan_relations` carries the same guard for the same reason.
  #}
  {% if execute %}
    {% set sql %}
      DO $$ BEGIN
        IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_app') THEN
          GRANT USAGE ON SCHEMA marts TO stacks_app;
          GRANT SELECT ON ALL TABLES IN SCHEMA marts TO stacks_app;
        END IF;

        IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_readonly') THEN
          GRANT USAGE ON SCHEMA marts TO stacks_readonly;
          GRANT SELECT ON ALL TABLES IN SCHEMA marts TO stacks_readonly;
        END IF;
      END $$;
    {% endset %}
    {% do run_query(sql) %}

    {#
      The log line names the roles it actually found, not the roles it tried
      for. "granted SELECT on marts" was the previous wording and it was
      printed by a branch that never ran — but even when it does run, it would
      be true of a database with neither role, because both grants sit behind
      `IF EXISTS`. Reporting the roles present is the difference between
      recording an intention and recording an outcome.
    #}
    {% set present = run_query(
         "SELECT coalesce(string_agg(rolname, ', ' ORDER BY rolname), 'none') "
         ~ "FROM pg_roles WHERE rolname IN ('stacks_app', 'stacks_readonly')"
       ) %}
    {{ log("marts SELECT granted to: " ~ present.columns[0].values()[0], info=True) }}
  {% endif %}
{% endmacro %}
