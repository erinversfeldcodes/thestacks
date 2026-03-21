{{ config(materialized='view') }}

select
    id as author_id,
    name,
    website_url,
    rss_feed_url,
    created_at,
    updated_at,
    website_url is not null as has_website,
    rss_feed_url is not null as has_rss_feed
from {{ ref('stg_authors') }}
