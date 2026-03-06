{{ config(
    materialized='view'
) }}

select
    id,
    name,
    website_url,
    rss_feed_url,
    open_library_id,
    bio,
    created_at,
    updated_at
from {{ source('op', 'authors') }}
