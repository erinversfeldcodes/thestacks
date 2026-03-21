{{ config(materialized='view') }}

select
    event_type,
    count(*) as event_count,
    min(occurred_at) as earliest,
    max(occurred_at) as latest
from {{ ref('stg_event_log') }}
group by event_type
