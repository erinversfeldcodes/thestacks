{{ config(materialized='view') }}

select
    id,
    source_name,
    source_type,
    status,
    consecutive_failures,
    total_successes,
    total_failures,
    last_success_at,
    last_failure_at,
    last_failure_reason
from {{ ref('stg_source_health_checks') }}
