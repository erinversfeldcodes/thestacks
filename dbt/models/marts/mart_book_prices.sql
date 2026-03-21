{{ config(materialized='view') }}

select
    book_id,
    store_name,
    price_cents,
    currency,
    in_stock,
    scraped_at
from {{ ref('int_price_trends') }}
where recency_rank = 1
