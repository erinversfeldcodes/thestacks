{{ config(materialized='view') }}

select
    book_id,
    count(*) as placement_count,
    count(*) filter (
        where removed_at is not null
        and placed_at is not null
    ) as reread_indicator_count,
    coalesce(
        avg(personal_rating), 0
    ) as avg_personal_rating,
    max(placed_at) as latest_placed_at
from {{ ref('stg_bookshelf_placements') }}
group by book_id
