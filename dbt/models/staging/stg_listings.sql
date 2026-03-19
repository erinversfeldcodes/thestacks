{{ config(
    materialized='view'
) }}

select
    id,
    book_id,
    seller_id,
    status,
    pricing_mode,
    price_cents,
    currency,
    condition,
    description,
    photo_urls,
    listed_at,
    expires_at,
    sold_at,
    created_at,
    updated_at
from {{ source('op', 'listings') }}
