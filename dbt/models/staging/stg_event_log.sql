{{ config(
    materialized='view'
) }}

select
    id,
    event_type,
    aggregate_type,
    aggregate_id,
    schema_version,
    payload,
    metadata,
    occurred_at,
    published_at
from {{ source('op', 'event_log') }}
