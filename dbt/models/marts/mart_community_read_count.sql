{{ config(materialized='view') }}

select
    bp.book_id,
    count(distinct bs.user_id) as read_count
from {{ ref('stg_bookshelf_placements') }} as bp
inner join {{ ref('stg_bookshelves') }} as bs
    on bp.bookshelf_id = bs.id
where bp.removed_at is null
group by bp.book_id
