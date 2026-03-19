{{ config(
    materialized='view'
) }}

select
    id,
    source_name,
    source_type,
    last_success_at,
    last_failure_at,
    last_failure_reason,
    consecutive_failures,
    total_successes,
    total_failures,
    status,
    created_at,
    updated_at
from {{ source('op', 'source_health_checks') }}
