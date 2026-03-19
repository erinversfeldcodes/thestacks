{{ config(
    materialized='view'
) }}

select
    id,
    group_id,
    user_id,
    role,
    joined_at,
    created_at
from {{ source('op', 'group_members') }}
