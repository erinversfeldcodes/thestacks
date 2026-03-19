{{ config(
    materialized='view'
) }}

select
    id,
    resource_type,
    resource_id,
    granted_to_id,
    granted_by_id,
    created_at
from {{ source('op', 'visibility_grants') }}
