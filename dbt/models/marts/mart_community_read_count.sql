{{ config(
    materialized='incremental',
    unique_key='book_id',
    on_schema_change='sync_all_columns',
    post_hook="{{ prune_absent_keys('book_id', ref('stg_bookshelf_placements')) }}"
) }}

{#
  ⚠️ The prune source is the PLACEMENTS view, not a list of books. This mart is
  a count grouped over placements, so the row that must disappear is the one for
  a book whose LAST placement was deleted — pruning against `stg_books` would
  keep it forever, because the book itself still exists.

  ⚠️ THE HOOK CLOSES HALF THE PROBLEM, and the halves are worth separating
  because the first draft of this comment claimed the whole thing. Measured:

    - a book whose last placement is hard-deleted: the key vanishes upstream,
      the hook removes the row, and an incremental refresh now leaves the mart
      correct (ABSENT). Previously the row survived indefinitely.
    - a book that loses ONE of three placements: the key still exists, so the
      hook correctly leaves the row — but the COUNT is stale, because a deletion
      updates no surviving row and the book therefore never enters the
      `is_incremental()` window. Measured 3 while the truth was 2.

  The second case is only reachable by a HARD delete. The application's own
  removal path sets `removed_at` through a changeset, which bumps `updated_at`
  and so does pull the book into the window — the count recomputes correctly
  there. The hard-delete path is the FK cascade on account erasure.

  So the residual exposure is narrow and stated rather than hidden: after an
  erasure, books the erased reader had shelved carry a count too high by one
  until the daily `dbt build --full-refresh`. The mart holds no identifier, so
  nothing personal is retained — it is wrong data on a bounded window, recorded
  in this model's `deletion_handling` meta.
#}

select
    bp.book_id,
    count(distinct bs.user_id) filter (
        where bp.removed_at is null
    ) as read_count,
    current_timestamp as last_refreshed_at
from {{ ref('stg_bookshelf_placements') }} as bp
inner join {{ ref('stg_bookshelves') }} as bs
    on bp.bookshelf_id = bs.id

{% if is_incremental() %}
where
    bp.book_id in (
        select bp2.book_id
        from
            {{ ref('stg_bookshelf_placements') }}
                as bp2
        where
            bp2.created_at > (
                select max(prev.last_refreshed_at)
                from {{ this }} as prev
            )
            or bp2.updated_at > (
                select max(prev.last_refreshed_at)
                from {{ this }} as prev
            )
    )
{% endif %}

group by bp.book_id
