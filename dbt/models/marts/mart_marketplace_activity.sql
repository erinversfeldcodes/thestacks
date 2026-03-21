{{ config(materialized='view') }}

select
    status,
    count(*) as listing_count
from {{ ref('stg_listings') }}
group by status
