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
    visibility,
    listing_mode,
    listing_status,
    listing_price_cents,
    listing_min_price_cents,
    created_at,
    updated_at
from {{ source('op', 'bookshelf_placements') }}
