{{ config(
    materialized='view'
) }}

select
    id,
    title,
    author_id,
    description,
    language,
    subjects,
    bisac_codes,
    visibility_tier,
    created_at,
    updated_at
from {{ source('op', 'books') }}
