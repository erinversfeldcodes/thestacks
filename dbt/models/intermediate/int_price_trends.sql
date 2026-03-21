{{ config(materialized='view') }}

select
    ps.id,
    ps.book_id,
    ps.store_id,
    bs.name as store_name,
    bs.country_code as store_country_code,
    ps.price_cents,
    ps.currency,
    ps.in_stock,
    ps.url,
    ps.scraped_at,
    row_number() over (
        partition by ps.book_id, ps.store_id
        order by ps.scraped_at desc
    ) as recency_rank
from {{ source('op', 'price_snapshots') }} as ps
left join {{ source('op', 'bookstores') }} as bs
    on ps.store_id = bs.id
