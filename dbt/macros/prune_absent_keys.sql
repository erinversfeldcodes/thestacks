{#
  Delete rows from an incremental model whose key no longer exists upstream.

  ⚠️ WHY THIS EXISTS. An incremental model's `is_incremental()` window selects
  rows whose SURVIVING `created_at`/`updated_at` is newer than the last refresh.
  A DELETE upstream updates no surviving row, so a deleted entity never enters
  the window and its mart row persists forever.

  Measured on a development database before this macro: a book's `read_count`
  read 3; one of its placements was hard-deleted, which is exactly what an
  account erasure's FK cascade does; the true count became 2; an incremental
  refresh ran and selected nothing (`INSERT 0 0`); the mart still read **3**.

  The daily pass now runs `dbt build --full-refresh`, which rebuilds from
  scratch and is therefore correct by construction. But the EVENT-DRIVEN
  selective refresh (`DbtRefreshJob`) stays incremental for latency, so without
  this hook a deleted entity's row is wrong for up to a day. This closes that
  window instead of documenting it.

  ⚠️ `NOT EXISTS`, not `NOT IN`. A `NOT IN` subquery that yields a single NULL
  matches NOTHING, so the prune would silently stop pruning — the exact failure
  mode this macro exists to fix, reintroduced one level down.

  Guarded on `is_incremental()`: a full refresh rebuilds the table, so there is
  nothing to prune and `this` may not hold what the guard assumes.

  Usage, as a model post-hook:
      {{ config(
          materialized='incremental',
          unique_key='book_id',
          post_hook="{{ prune_absent_keys('book_id', ref('stg_books')) }}"
      ) }}
#}
{% macro prune_absent_keys(key, source_relation) %}
  {% if is_incremental() %}
    DELETE FROM {{ this }} AS target
     WHERE NOT EXISTS (
       SELECT 1
         FROM {{ source_relation }} AS upstream
        WHERE upstream.{{ key }} = target.{{ key }}
     )
  {% endif %}
{% endmacro %}
