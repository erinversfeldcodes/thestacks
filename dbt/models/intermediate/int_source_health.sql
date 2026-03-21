{{ config(materialized='view') }}

select
    source_name,
    status,
    last_success_at,
    last_failure_at,
    created_at,
    updated_at,
    updated_at as last_checked_at,
    consecutive_failures,
    total_successes,
    total_failures,
    total_successes + total_failures as total_checks,
    case
        when total_successes + total_failures > 0
            then round(
                total_successes::numeric
                / (total_successes + total_failures)
                * 100,
                1
            )
        else 0
    end as uptime_pct
from {{ ref('stg_source_health_checks') }}
