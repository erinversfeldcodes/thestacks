{{ config(
    materialized='view'
) }}

select
    id,
    owner_id,
    name,
    type,
    visibility,
    created_at,
    updated_at
from {{ source('op', 'groups') }}
