{#
  Drop relations in the warehouse schemas that no longer have a backing model.

  ⚠️ WHY THIS EXISTS, and why it must run before the first scheduled refresh on
  a deployed stack.

  Deleting a dbt model file does NOT drop the relation it built. A wave of mart
  deletions removed nine orphan marts plus one more from `dbt/models/marts/`,
  and the model-count drift gate went green — because it compares model FILES
  to the manifest and cannot see the database. Measured on a dev database after
  the first successful run: 15 relations in `marts`, 4 model files. The other
  eleven were views reading from staging models that no longer exist.

  On deployed stacks this was harmless for exactly one reason: dbt had never
  run there, so the relations were never created. That stops being true the
  moment the scheduled refresh works — at which point those views would sit in
  `marts` failing on select rather than on build, invisible to every gate.

  SAFETY. This drops only what dbt itself would consider unmanaged:

    - the three warehouse schemas and nothing else, so `op`, `audit`, `cache`
      and `public` can never be touched;
    - relations whose name is absent from `graph.nodes`, which is dbt's own
      manifest of what this project builds;
    - with a `--dry-run` default. It REPORTS by default and only drops when
      explicitly asked, because a macro that deletes relations on import is a
      worse problem than the one it solves.

  Usage:
      dbt run-operation drop_orphan_relations                  # report only
      dbt run-operation drop_orphan_relations --args '{dry_run: false}'
#}
{% macro drop_orphan_relations(dry_run=True) %}
  {% if execute %}
    {% set managed = [] %}
    {% for node in graph.nodes.values() %}
      {% if node.resource_type == 'model' %}
        {% do managed.append(node.schema ~ '.' ~ node.alias) %}
      {% endif %}
    {% endfor %}

    {#
      ⚠️ `table_type` is selected, not assumed. The first version issued
      `DROP VIEW IF EXISTS` followed by `DROP TABLE IF EXISTS` for every
      relation — and in Postgres `DROP TABLE` against a VIEW is an ERROR, not a
      no-op, even with `IF EXISTS`. That aborted the operation partway: six of
      fifteen dropped, nine left, and a "success" exit. Found by running it.
    #}
    {#
      ⚠️ `wh` is in this list, and it was not until 2026-10-16.
      `dbt/profiles.yml` sets `schema: wh` as the default target, so a model
      filed outside the three layer directories materialises THERE. The project
      keeps `wh` for exactly that reason — a misfiling should show up as rows in
      a schema nothing reads rather than as a dbt error someone "fixes" by
      creating a schema — and the issue that made that decision says the orphan
      sweep is what would surface it.

      It would not have. The sweep looked at three schemas and `wh` was not one
      of them, so a stray relation there was the only kind of orphan this macro
      could never see: unswept, unread, and permanent. The safety net named in
      the decision did not cover the case the decision existed for.

      `wh` is expected to hold nothing, so every relation found there is an
      orphan by construction.
    #}
    {% set find_sql %}
      SELECT table_schema, table_name, table_type
      FROM information_schema.tables
      WHERE table_schema IN ('staging', 'intermediate', 'marts', 'wh')
      ORDER BY table_schema, table_name
    {% endset %}

    {% set existing = run_query(find_sql) %}
    {% set orphans = [] %}

    {% for row in existing.rows %}
      {% set qualified = row[0] ~ '.' ~ row[1] %}
      {% if qualified not in managed %}
        {% set kind = 'VIEW' if row[2] == 'VIEW' else 'TABLE' %}
        {% do orphans.append((qualified, kind)) %}
      {% endif %}
    {% endfor %}

    {% if orphans | length == 0 %}
      {{ log("no orphan relations in staging/intermediate/marts", info=True) }}
    {% elif dry_run %}
      {{ log("ORPHAN RELATIONS (no backing model) — " ~ orphans | length ~ " found:", info=True) }}
      {% for o, kind in orphans %}
        {{ log("  " ~ kind ~ "  " ~ o, info=True) }}
      {% endfor %}
      {{ log("re-run with --args '{dry_run: false}' to drop them", info=True) }}
    {% else %}
      {% for o, kind in orphans %}
        {% do run_query("DROP " ~ kind ~ " IF EXISTS " ~ o ~ " CASCADE") %}
        {{ log("dropped orphan " ~ kind | lower ~ " " ~ o, info=True) }}
      {% endfor %}
    {% endif %}
  {% endif %}
{% endmacro %}
