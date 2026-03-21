{{ config(materialized='view') }}

select
    book_id,
    count(distinct bookshelf_id) as read_count
from {{ ref('stg_bookshelf_placements') }}
where removed_at is null
group by book_id
