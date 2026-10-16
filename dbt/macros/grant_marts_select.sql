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
{% macro grant_marts_select() %}
  {% if target.name != 'dev' or env_var('DBT_GRANT_IN_DEV', 'false') == 'true' %}
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
    {{ log("granted SELECT on marts to the app and read-only roles", info=True) }}
  {% else %}
    {{ log("skipping marts grants on the dev target; set DBT_GRANT_IN_DEV=true to exercise them", info=True) }}
  {% endif %}
{% endmacro %}
