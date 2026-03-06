{{ config(
    materialized='view'
) }}

select
    id,
    user_id,
    name,
    created_at,
    updated_at
from {{ source('op', 'bookshelves') }}
