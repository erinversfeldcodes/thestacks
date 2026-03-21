{{ config(materialized='view') }}

select
    id,
    'bookstore' as event_source,
    store_id as venue_id,
    author_id,
    title,
    description,
    event_date,
    null as recurrence,
    url as source_url,
    scraped_at
from {{ source('op', 'bookstore_events') }}
where event_date >= current_date

union all

select
    id,
    'third_space' as event_source,
    space_id as venue_id,
    null as author_id,
    title,
    description,
    event_date,
    recurrence,
    source_url,
    scraped_at
from {{ source('op', 'third_space_events') }}
where event_date >= current_date
