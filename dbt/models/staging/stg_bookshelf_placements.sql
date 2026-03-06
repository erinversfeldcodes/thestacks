{{ config(
    materialized='view'
) }}

select
    id,
    book_id,
    bookshelf_id,
    position,
    placed_at,
    removed_at,
    formats,
    personal_rating,
    notes,
    created_at,
    updated_at
from {{ source('op', 'bookshelf_placements') }}
