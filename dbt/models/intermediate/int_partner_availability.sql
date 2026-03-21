{{ config(materialized='view') }}

select
    book_id,
    count(*) as total_snapshot_count,
    count(*) filter (
        where in_stock = true
    ) as in_stock_count,
    count(distinct store_id) as store_count,
    count(distinct store_id) filter (
        where in_stock = true
    ) as stores_in_stock_count,
    max(scraped_at) as latest_scraped_at
from {{ source('op', 'price_snapshots') }}
group by book_id
