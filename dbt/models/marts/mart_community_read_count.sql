{{ config(
    materialized='incremental',
    unique_key='book_id',
    on_schema_change='sync_all_columns'
) }}

-- Issue #279 — tombstone semantics for last-placement removal.
--
-- This mart is INCREMENTAL with a delete+insert strategy (unique_key =
-- book_id): each run computes a batch of affected book_ids, deletes those
-- book_ids from the target, and re-inserts the recomputed rows. A book_id that
-- is absent from the batch RESULT is never deleted — so if the recompute
-- produces no row for a book, its previous (now stale) row survives.
--
-- The naive body filtered `where removed_at is null` in the WHERE clause. When
-- a book's LAST active placement was soft-deleted, that book still entered the
-- incremental batch (remove_book bumps updated_at, and the batch scan below
-- does not filter removed_at), but the filtered recompute produced NO row for
-- it, so delete+insert left the stale non-zero read_count in place — the count
-- never dropped to zero without a --full-refresh.
--
-- Fix: aggregate over ALL placements (active and soft-deleted) and count only
-- the active ones via a FILTER, instead of filtering removed_at in WHERE. A
-- book whose last active placement was removed now yields a `read_count = 0`
-- row, which delete+insert uses to replace the stale row (keep-and-zero
-- semantics). Because the WHERE no longer drops soft-deleted-only books,
-- full-refresh and incremental runs agree: both emit a 0 row for a book with
-- only removed placements.

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
