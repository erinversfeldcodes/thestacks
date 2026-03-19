{{ config(
    materialized='view'
) }}

select
    id,
    placement_id,
    buyer_id,
    status,
    created_at,
    updated_at
from {{ source('op', 'offer_threads') }}
