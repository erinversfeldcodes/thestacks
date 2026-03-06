{{ config(
    materialized='view'
) }}

select
    id,
    book_id,
    from_bookshelf,
    to_bookshelf,
    moved_at
from {{ source('op', 'bookshelf_placement_history') }}
