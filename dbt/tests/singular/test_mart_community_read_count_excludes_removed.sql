-- Issue #116 punch #14a: mart_community_read_count must count only ACTIVE
-- placements. A soft-deleted placement (removed_at IS NOT NULL) contributes a
-- distinct user_id to a book's read_count only if that same (book, user) also
-- has an active placement; a user whose ONLY placement of a book is removed
-- must not be counted.
--
-- The mart already filters `where removed_at is null`, but that guard is easy
-- to drop in a refactor and silently inflates every community count. This test
-- recomputes the count the mart SHOULD produce if soft-deletes are honoured and
-- fails on any book whose published read_count exceeds it — i.e. any removed
-- placement that leaked into the total.
--
-- A non-empty result is a failure. Counts are keyed by ids only (no PII).
with active_counts as (
    select
        bp.book_id,
        count(distinct bs.user_id) as expected_read_count
    from {{ ref('stg_bookshelf_placements') }} as bp
    inner join {{ ref('stg_bookshelves') }} as bs
        on bp.bookshelf_id = bs.id
    where bp.removed_at is null
    group by bp.book_id
)

select
    m.book_id,
    m.read_count as mart_read_count,
    coalesce(a.expected_read_count, 0) as expected_read_count
from {{ ref('mart_community_read_count') }} as m
left join active_counts as a
    on m.book_id = a.book_id
where m.read_count > coalesce(a.expected_read_count, 0)
