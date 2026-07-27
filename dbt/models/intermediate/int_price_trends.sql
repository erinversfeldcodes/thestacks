{{ config(materialized='view') }}

-- Recency is ranked per (edition, store), not per (work, store).
--
-- A price is a fact about an edition: shops stock whichever edition they
-- stock, at different prices. Exclusive Books carries six ISBNs of The Name
-- of the Rose at prices from R400 to R411. Partitioning by book_id blended
-- those into one series, so `recency_rank = 1` kept whichever edition happened
-- to be scraped last and the rest disappeared from mart_book_prices entirely.

select
    ps.id,
    ps.book_id,
    ps.book_edition_id,
    be.isbn,
    ps.store_id,
    bs.name as store_name,
    bs.country_code as store_country_code,
    ps.price_cents,
    ps.currency,
    ps.in_stock,
    ps.url,
    ps.scraped_at,
    row_number() over (
        partition by ps.book_edition_id, ps.store_id
        order by ps.scraped_at desc
    ) as recency_rank
from {{ source('op', 'price_snapshots') }} as ps
left join {{ source('op', 'bookstores') }} as bs
    on ps.store_id = bs.id
left join {{ source('op', 'book_editions') }} as be
    on ps.book_edition_id = be.id
