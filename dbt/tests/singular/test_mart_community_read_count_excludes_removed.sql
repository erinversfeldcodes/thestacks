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
