{{ config(materialized='view') }}

-- One row per (edition, store): the latest price for each edition a store
-- carries. Selecting only book_id here would have silently collapsed several
-- editions of one work into indistinguishable rows.

select
    book_id,
    book_edition_id,
    isbn,
    store_name,
    price_cents,
    currency,
    in_stock,
    scraped_at
from {{ ref('int_price_trends') }}
where recency_rank = 1
