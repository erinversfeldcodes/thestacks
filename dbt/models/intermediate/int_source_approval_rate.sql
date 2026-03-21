{{ config(materialized='view') }}

select
    type as source_type,
    count(*) as source_count,
    count(*) filter (where status = 'approved') as approved_count,
    count(*) filter (where status = 'dismissed') as dismissed_count,
    count(*) filter (where status = 'pending_review') as pending_count,
    count(*) filter (where status = 'excluded') as excluded_count
from {{ source('op', 'discovered_sources') }}
group by type
