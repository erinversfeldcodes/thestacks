{{ config(
    materialized='view'
) }}

select
    id,
    blocker_id,
    blocked_id,
    created_at
from {{ source('op', 'user_blocks') }}
