{{ config(materialized='view') }}

select
    aggregate_type,
    max(occurred_at) as last_event_at
from {{ ref('stg_event_log') }}
group by aggregate_type
