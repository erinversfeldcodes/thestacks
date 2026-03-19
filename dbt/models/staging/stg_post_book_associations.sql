{{ config(
    materialized='view'
) }}

select
    id,
    post_id,
    book_id,
    confidence,
    reasoning,
    source,
    visible,
    created_at,
    updated_at
from {{ source('op', 'post_book_associations') }}
